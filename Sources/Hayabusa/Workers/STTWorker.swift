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
//   dev mode (HAYABUSA_STT_PROD_MODE が未設定 / false):
//     {
//       "transcript": "...full text...",
//       "language":  "ja",
//       "model":     "ggml-large-v3-turbo-q5_0.bin",
//       "audioPath": "...",
//       "segmentCount": 12,
//       "elapsedMs": 42000
//     }
//   production mode (HAYABUSA_STT_PROD_MODE=1):
//     transcript と audioPath は載せず、件数 / バイト数 / SHA-256 だけ返す。
//     transcript は edge に保管しつつ、command-room には ref と要約 (別 job) を投げる
//     運用にする想定 (contracts/openpbx-event-v1 §8 PII 規約参照)。
//
// 環境変数:
//   HAYABUSA_WHISPER_BIN          (必須) whisper-cli へのパス
//   HAYABUSA_WHISPER_MODEL        (必須) モデル .bin パス
//   HAYABUSA_WHISPER_LANG         (任意) 既定 "ja"
//   HAYABUSA_WHISPER_THREADS      (任意) 既定 8
//   HAYABUSA_STT_TIMEOUT_SEC      (任意) 既定 300。経過したら SIGTERM → 2 秒後 SIGKILL
//   HAYABUSA_STT_RECORDINGS_ROOT  (任意) audio file は realpath がこの prefix 配下である必要あり
//   HAYABUSA_STT_MAX_AUDIO_MB     (任意) audio file の最大サイズ (MB)。既定 200
//   HAYABUSA_STT_PROD_MODE        (任意) 1 / true で production mode (transcript redact)

import Foundation
import Darwin
import CryptoKit

public struct STTWorker: Worker {
    public let jobType: String

    private let whisperBin: String
    private let modelPath: String
    private let language: String
    /// whisper-cli の threads オプション。多すぎても効果薄。
    private let threads: Int
    private let timeoutSec: Int
    private let recordingsRoot: String?
    private let maxAudioBytes: Int
    private let productionMode: Bool

    private static let allowedExtensions: Set<String> = ["wav", "mp3", "m4a", "flac", "ogg", "opus", "aac"]

    public init(
        jobType: String = "stt.transcribe",
        whisperBin: String,
        modelPath: String,
        language: String = "ja",
        threads: Int = 8,
        timeoutSec: Int = 300,
        recordingsRoot: String? = nil,
        maxAudioBytes: Int = 200 * 1024 * 1024,
        productionMode: Bool = false
    ) {
        self.jobType = jobType
        self.whisperBin = whisperBin
        self.modelPath = modelPath
        self.language = language
        self.threads = threads
        self.timeoutSec = timeoutSec
        self.recordingsRoot = recordingsRoot
        self.maxAudioBytes = maxAudioBytes
        self.productionMode = productionMode
    }

    /// env から作る factory。HAYABUSA_WHISPER_BIN / HAYABUSA_WHISPER_MODEL /
    /// HAYABUSA_WHISPER_LANG / HAYABUSA_WHISPER_THREADS / HAYABUSA_STT_TIMEOUT_SEC /
    /// HAYABUSA_STT_RECORDINGS_ROOT / HAYABUSA_STT_MAX_AUDIO_MB / HAYABUSA_STT_PROD_MODE。
    /// HAYABUSA_WHISPER_BIN または HAYABUSA_WHISPER_MODEL が未設定なら nil。
    public static func fromEnv(env: [String: String] = ProcessInfo.processInfo.environment) -> STTWorker? {
        guard
            let bin = env["HAYABUSA_WHISPER_BIN"], !bin.isEmpty,
            let model = env["HAYABUSA_WHISPER_MODEL"], !model.isEmpty
        else { return nil }
        let lang = env["HAYABUSA_WHISPER_LANG"] ?? "ja"
        let threads = Int(env["HAYABUSA_WHISPER_THREADS"] ?? "8") ?? 8
        let timeoutSec = Int(env["HAYABUSA_STT_TIMEOUT_SEC"] ?? "300") ?? 300
        let root = env["HAYABUSA_STT_RECORDINGS_ROOT"].flatMap { $0.isEmpty ? nil : $0 }
        let maxMb = Int(env["HAYABUSA_STT_MAX_AUDIO_MB"] ?? "200") ?? 200
        let maxAudioBytes = max(1, maxMb) * 1024 * 1024
        let prodRaw = env["HAYABUSA_STT_PROD_MODE"]?.lowercased() ?? ""
        let productionMode = prodRaw == "1" || prodRaw == "true" || prodRaw == "yes"
        return STTWorker(
            whisperBin: bin,
            modelPath: model,
            language: lang,
            threads: threads,
            timeoutSec: timeoutSec,
            recordingsRoot: root,
            maxAudioBytes: maxAudioBytes,
            productionMode: productionMode
        )
    }

    public func execute(job: JobEnvelope) async -> JobResultReport {
        guard let rawAudioPath = job.payload["audioHostPath"]?.stringValue, !rawAudioPath.isEmpty else {
            return .failed(error: "missing audioHostPath in payload", retryable: false)
        }
        switch validateAudioPath(rawAudioPath) {
        case .failure(let report):
            return report
        case .success:
            break
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
            "-f", rawAudioPath,
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

        let stdoutSink = PipeSink()
        let stderrSink = PipeSink()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdoutSink.append(chunk)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderrSink.append(chunk)
            }
        }

        let start = Date()
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return .failed(error: "spawn whisper-cli failed: \(error)", retryable: true)
        }

        let timedOut = AtomicFlag()
        let timeoutTask = Task.detached(priority: .background) { [timeoutSec, process] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, timeoutSec)) * 1_000_000_000)
            if process.isRunning {
                timedOut.set()
                process.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                process.waitUntilExit()
                cont.resume()
            }
        }
        timeoutTask.cancel()

        // Detach the handlers before reading trailing buffer bytes.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        if timedOut.isSet() {
            return .failed(error: "whisper-cli timed out after \(timeoutSec)s", retryable: true)
        }
        if process.terminationStatus != 0 {
            let errStr = stderrSink.snapshotString()
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

        var resultDict: [String: JSONValue] = [
            "language": .string(language),
            "model": .string(modelFile),
            "segmentCount": .int(Int64(parsed.transcription.count)),
            "elapsedMs": .int(Int64(elapsedMs)),
        ]
        if productionMode {
            // command-room には transcript 本文を渡さず、edge 側で要約 / RAG 用途に
            // 留める前提。transcript の存在と長さだけ ack できるよう byte size のみ返す。
            let utf8 = Data(fullText.utf8)
            resultDict["transcriptBytes"] = .int(Int64(utf8.count))
            resultDict["transcriptSha256Prefix"] = .string(sha256Prefix(of: utf8))
            resultDict["redacted"] = .bool(true)
        } else {
            resultDict["transcript"] = .string(fullText)
            resultDict["audioPath"] = .string(rawAudioPath)
            resultDict["redacted"] = .bool(false)
        }
        return .succeeded(result: .object(resultDict))
    }

    // MARK: - Path validation

    private enum AudioValidationResult {
        case success
        case failure(JobResultReport)
    }

    private func validateAudioPath(_ rawPath: String) -> AudioValidationResult {
        // 1. Extension allowlist
        let ext = (rawPath as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, Self.allowedExtensions.contains(ext) else {
            return .failure(.failed(
                error: "audio extension not allowed: .\(ext) (allowed: \(Self.allowedExtensions.sorted().joined(separator: ",")))",
                retryable: false
            ))
        }

        // 2. Existence + size + type
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: rawPath)
        } catch {
            return .failure(.failed(error: "audio not found at \(rawPath): \(error)", retryable: false))
        }
        if let type = attrs[.type] as? FileAttributeType, type != .typeRegular {
            return .failure(.failed(error: "audio is not a regular file: \(type.rawValue)", retryable: false))
        }
        if let size = attrs[.size] as? NSNumber {
            let bytes = size.intValue
            if bytes > maxAudioBytes {
                return .failure(.failed(
                    error: "audio too large: \(bytes) bytes (limit \(maxAudioBytes))",
                    retryable: false
                ))
            }
        }

        // 3. Optional recordings root prefix check, resolving symlinks.
        if let root = recordingsRoot {
            let resolvedAudio = URL(fileURLWithPath: rawPath).resolvingSymlinksInPath().path
            let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
            // Ensure root ends with "/" so /foo does not match /foobar.
            let rootPrefix = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
            if !resolvedAudio.hasPrefix(rootPrefix) {
                return .failure(.failed(
                    error: "audio path outside HAYABUSA_STT_RECORDINGS_ROOT (\(resolvedRoot))",
                    retryable: false
                ))
            }
        }
        return .success
    }

    private func sha256Prefix(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        // Return only the first 16 hex chars — enough to correlate without revealing content.
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Internal helpers

/// Pipe からの非同期 chunk を蓄積。 readabilityHandler は別 thread から呼ばれるため lock で守る。
/// 暴走した stderr を抑えるため、内部 buffer は 1MB に capping。
private final class PipeSink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let cap = 1024 * 1024

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        if buffer.count > cap {
            buffer = buffer.suffix(cap)
        }
        lock.unlock()
    }

    func snapshotString() -> String {
        lock.lock()
        let copy = buffer
        lock.unlock()
        return String(data: copy, encoding: .utf8) ?? ""
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.lock(); value = true; lock.unlock() }
    func isSet() -> Bool { lock.lock(); let v = value; lock.unlock(); return v }
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
