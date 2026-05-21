// STT (音声認識) worker — whisper.cpp の whisper-cli を subprocess で叩く実装。
//
// Job payload (command-room normalize-pbx-edge.ts から):
//   {
//     "callRecordId": "uuid",
//     "workspaceId":  "uuid",
//     "audioHostPath": "/abs/path/to/recording.wav",  ← host filesystem 直 (dev)
//     "pbxInstanceId": "clinic-main",
//     "uniqueId": "1779...",
//     "callerExtension": "1001",
//     "calleeExtension": "1002",
//     "contentType": "audio/wav",
//     "sizeBytes": 12345
//   }
//
// 返却 (JobResultReport.result):
//   {
//     "transcript": "...全文...",
//     "language":  "ja",
//     "model":     "ggml-large-v3-turbo-q5_0.bin",
//     "audioPath": "...",
//     "segmentCount": 12,
//     "durationMs": 42000
//   }
//
// 注意: transcript 本文を command-room に送るのは, dev / local-AI 用途の
// 経路として割り切る。production では transcript を edge に置いて要約だけ
// 送る policy が望ましい (contracts/openpbx-event-v1 §8 PII 規約参照)。

import Foundation

public struct STTWorker: Worker {
    public let jobType: String

    private let whisperBin: String
    private let modelPath: String
    private let language: String
    /// whisper-cli の threads オプション。多すぎても効果薄。
    private let threads: Int

    public init(
        jobType: String = "stt.transcribe",
        whisperBin: String,
        modelPath: String,
        language: String = "ja",
        threads: Int = 8
    ) {
        self.jobType = jobType
        self.whisperBin = whisperBin
        self.modelPath = modelPath
        self.language = language
        self.threads = threads
    }

    /// env から作る factory。HAYABUSA_WHISPER_BIN / HAYABUSA_WHISPER_MODEL /
    /// HAYABUSA_WHISPER_LANG / HAYABUSA_WHISPER_THREADS。
    /// HAYABUSA_WHISPER_BIN または HAYABUSA_WHISPER_MODEL が未設定なら nil。
    public static func fromEnv(env: [String: String] = ProcessInfo.processInfo.environment) -> STTWorker? {
        guard
            let bin = env["HAYABUSA_WHISPER_BIN"], !bin.isEmpty,
            let model = env["HAYABUSA_WHISPER_MODEL"], !model.isEmpty
        else { return nil }
        let lang = env["HAYABUSA_WHISPER_LANG"] ?? "ja"
        let threads = Int(env["HAYABUSA_WHISPER_THREADS"] ?? "8") ?? 8
        return STTWorker(whisperBin: bin, modelPath: model, language: lang, threads: threads)
    }

    public func execute(job: JobEnvelope) async -> JobResultReport {
        guard let audioPath = job.payload["audioHostPath"]?.stringValue, !audioPath.isEmpty else {
            return .failed(error: "missing audioHostPath in payload", retryable: false)
        }
        guard FileManager.default.fileExists(atPath: audioPath) else {
            return .failed(error: "audio not found at \(audioPath)", retryable: false)
        }
        guard FileManager.default.fileExists(atPath: whisperBin) else {
            return .failed(error: "whisper-cli not found at \(whisperBin)", retryable: false)
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            return .failed(error: "whisper model not found at \(modelPath)", retryable: false)
        }

        let outBase = NSTemporaryDirectory() + "hayabusa-whisper-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(atPath: outBase + ".json")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperBin)
        process.arguments = [
            "-m", modelPath,
            "-f", audioPath,
            "-of", outBase,
            "--output-json",
            "--language", language,
            "--threads", String(threads),
            "--no-prints",
        ]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let start = Date()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failed(error: "spawn whisper-cli failed: \(error)", retryable: true)
        }
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        if process.terminationStatus != 0 {
            let errStr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failed(
                error: "whisper exit \(process.terminationStatus): \(errStr.prefix(500))",
                retryable: true
            )
        }

        let jsonURL = URL(fileURLWithPath: outBase + ".json")
        let parsed: WhisperOutput
        do {
            let data = try Data(contentsOf: jsonURL)
            parsed = try JSONDecoder().decode(WhisperOutput.self, from: data)
        } catch {
            return .failed(error: "parse whisper output failed: \(error)", retryable: false)
        }

        let fullText = parsed.transcription
            .map { $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let modelFile = (modelPath as NSString).lastPathComponent

        let result: JSONValue = .object([
            "transcript": .string(fullText),
            "language": .string(language),
            "model": .string(modelFile),
            "audioPath": .string(audioPath),
            "segmentCount": .int(Int64(parsed.transcription.count)),
            "elapsedMs": .int(Int64(elapsedMs)),
        ])
        return .succeeded(result: result)
    }
}

// whisper.cpp の --output-json が出す JSON 構造の最小デコード。
// 全体は { systeminfo, model, params, result, transcription:[{...}] }。
// segment ごとに text を持つので join で全文を組み立てる。
private struct WhisperOutput: Codable {
    struct Segment: Codable {
        let text: String
    }
    let transcription: [Segment]
}
