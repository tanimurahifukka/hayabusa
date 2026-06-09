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
//   HAYABUSA_WHISPER_SERVER_URL   (任意) 常駐 whisper-server の URL (例 http://127.0.0.1:7892)。
//                                 設定時は HTTP モード優先、失敗時に whisper-cli へフォールバック
//   HAYABUSA_WHISPER_PROMPT           (任意) initial prompt の既定値
//   HAYABUSA_WHISPER_PROMPT_VOICEMAIL (任意) payload sttKind="voicemail" 用 prompt
//   HAYABUSA_WHISPER_PROMPT_CLINICAL  (任意) payload sttKind="clinical" (診療 9010) 用 prompt
//   HAYABUSA_STT_TRANSCRIPTS_DIR  (任意) transcript 全文の edge 保存先。設定時は
//                                 <dir>/<uniqueId>.txt に保存し result に transcriptRef を載せる
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
    /// GPU(Metal) を無効化して CPU 推論にする。launchd(LaunchAgent) 配下では
    /// GUI/WindowServer セッションが無く Metal の GPU 初期化がデッドロックするため、
    /// 常駐ディスパッチャからの実行では CPU-only にする必要がある。
    private let noGpu: Bool
    /// 常駐 whisper-server (GUI セッション LaunchAgent) の URL。設定時は HTTP モード。
    private let serverURL: URL?
    /// payload sttKind → initial prompt。医療用語バイアス用 (同音異義語抑制)。
    private let kindPrompts: [String: String]
    private let defaultPrompt: String?
    /// transcript 全文の edge 保存先。cloud には transcriptRef のみ渡す。
    private let transcriptsDir: String?

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
        productionMode: Bool = false,
        noGpu: Bool = false,
        serverURL: URL? = nil,
        kindPrompts: [String: String] = [:],
        defaultPrompt: String? = nil,
        transcriptsDir: String? = nil
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
        self.noGpu = noGpu
        self.serverURL = serverURL
        self.kindPrompts = kindPrompts
        self.defaultPrompt = defaultPrompt
        self.transcriptsDir = transcriptsDir
    }

    /// App 起動ログ用。
    public var modeDescription: String {
        serverURL != nil ? "server(\(serverURL!.absoluteString))+cli-fallback" : "cli"
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
        let noGpuRaw = env["HAYABUSA_STT_NO_GPU"]?.lowercased() ?? ""
        let noGpu = noGpuRaw == "1" || noGpuRaw == "true" || noGpuRaw == "yes"
        let serverURL = env["HAYABUSA_WHISPER_SERVER_URL"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .flatMap(URL.init(string:))
        var kindPrompts: [String: String] = [:]
        if let p = env["HAYABUSA_WHISPER_PROMPT_VOICEMAIL"], !p.isEmpty { kindPrompts["voicemail"] = p }
        if let p = env["HAYABUSA_WHISPER_PROMPT_CLINICAL"], !p.isEmpty { kindPrompts["clinical"] = p }
        let defaultPrompt = env["HAYABUSA_WHISPER_PROMPT"].flatMap { $0.isEmpty ? nil : $0 }
        let transcriptsDir = env["HAYABUSA_STT_TRANSCRIPTS_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        return STTWorker(
            whisperBin: bin,
            modelPath: model,
            language: lang,
            threads: threads,
            timeoutSec: timeoutSec,
            recordingsRoot: root,
            maxAudioBytes: maxAudioBytes,
            productionMode: productionMode,
            noGpu: noGpu,
            serverURL: serverURL,
            kindPrompts: kindPrompts,
            defaultPrompt: defaultPrompt,
            transcriptsDir: transcriptsDir
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

        // kind 別 initial prompt: payload の sttKind ("clinical" = 診療 9010 / "voicemail")
        // を env 設定のプロンプトに解決する。プロンプトは語彙のみで PII を含まない。
        let sttKind = job.payload["sttKind"]?.stringValue
        let prompt = sttKind.flatMap { kindPrompts[$0] } ?? defaultPrompt

        let start = Date()
        var fullText: String?
        var segmentCount: Int?
        var engineMode = "cli"

        // 常駐 whisper-server (HTTP) 優先。失敗時は whisper-cli へフォールバック。
        if let serverURL {
            let client = WhisperHTTPClient(baseURL: serverURL, timeoutSec: timeoutSec)
            do {
                fullText = try await client.transcribe(audioPath: rawAudioPath, prompt: prompt)
                engineMode = "server"
            } catch {
                FileHandle.standardError.write(Data(
                    "[STTWorker] whisper-server failed, falling back to whisper-cli: \(error)\n".utf8))
            }
        }

        if fullText == nil {
            switch await runWhisperCli(audioPath: rawAudioPath, prompt: prompt) {
            case .failure(let report):
                return report
            case .success(let text, let segments):
                fullText = text
                segmentCount = segments
            }
        }

        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
        let text = Self.stripSilenceArtifact(fullText ?? "")
        let modelFile = (modelPath as NSString).lastPathComponent

        // transcript 全文は edge に保存し、cloud には transcriptRef のみ渡す
        // (contracts/openpbx-event-v1 §8)。後段の llm.summarize_call がこの ref を解決する。
        let transcriptRef = persistTranscript(text, job: job)

        var resultDict: [String: JSONValue] = [
            "language": .string(language),
            "model": .string(modelFile),
            "engine": .string(engineMode),
            "elapsedMs": .int(Int64(elapsedMs)),
        ]
        if let segmentCount {
            resultDict["segmentCount"] = .int(Int64(segmentCount))
        }
        if let transcriptRef {
            resultDict["transcriptRef"] = .string(transcriptRef)
        }
        if productionMode {
            // command-room には transcript 本文を渡さず、edge 側で要約 / RAG 用途に
            // 留める前提。transcript の存在と長さだけ ack できるよう byte size のみ返す。
            let utf8 = Data(text.utf8)
            resultDict["transcriptBytes"] = .int(Int64(utf8.count))
            resultDict["transcriptSha256Prefix"] = .string(sha256Prefix(of: utf8))
            resultDict["redacted"] = .bool(true)
        } else {
            resultDict["transcript"] = .string(text)
            resultDict["audioPath"] = .string(rawAudioPath)
            resultDict["redacted"] = .bool(false)
        }
        return .succeeded(result: .object(resultDict))
    }

    // MARK: - Silence artifact guard

    /// whisper が無音音声に対して出す既知の定型幻覚 (YouTube 字幕コーパス由来)。
    /// 電話の文字起こし全文がこれだけになることは無いため、完全一致のみ空文字に
    /// 置き換える (-sns / --no-speech-thold では抑制できないことを 2026-06 に実測確認)。
    /// 空 transcript は command-room 側で要約ジョブ enqueue がスキップされる。
    private static let silenceArtifacts: Set<String> = [
        "ご視聴ありがとうございました",
        "ご清聴ありがとうございました",
    ]

    static func stripSilenceArtifact(_ text: String) -> String {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "。", with: "")
        return silenceArtifacts.contains(normalized) ? "" : text
    }

    // MARK: - Transcript persistence (edge)

    /// transcript を <transcriptsDir>/<uniqueId>.txt に保存して transcriptRef を返す。
    /// 保存先未設定・空 transcript なら nil (従来挙動)。
    private func persistTranscript(_ text: String, job: JobEnvelope) -> String? {
        guard let dir = transcriptsDir, !text.isEmpty else { return nil }
        let rawId = job.payload["uniqueId"]?.stringValue ?? job.jobId
        let safeId = Self.sanitizeRefComponent(rawId)
        let pbx = Self.sanitizeRefComponent(job.payload["pbxInstanceId"]?.stringValue ?? "edge")
        let dirURL = URL(fileURLWithPath: dir)
        do {
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: dirURL.appendingPathComponent("\(safeId).txt"), options: .atomic)
            return "edge://\(pbx)/\(safeId)"
        } catch {
            FileHandle.standardError.write(Data("[STTWorker] transcript persist failed: \(error)\n".utf8))
            return nil
        }
    }

    /// transcriptRef の構成要素を path traversal 不能な文字集合に制限する。
    /// SummarizeWorker 側の解決と対で使う。
    static func sanitizeRefComponent(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { allowed.contains($0) }))
        return cleaned.isEmpty ? "unknown" : cleaned
    }

    // MARK: - whisper-cli subprocess

    private enum CliOutcome {
        case success(text: String, segmentCount: Int)
        case failure(JobResultReport)
    }

    private func runWhisperCli(audioPath rawAudioPath: String, prompt: String?) async -> CliOutcome {
        guard FileManager.default.fileExists(atPath: whisperBin) else {
            return .failure(.failed(error: "whisper-cli not found at \(whisperBin)", retryable: false))
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            return .failure(.failed(error: "whisper model not found at \(modelPath)", retryable: false))
        }

        let outBase = NSTemporaryDirectory() + "hayabusa-whisper-" + UUID().uuidString
        defer {
            try? FileManager.default.removeItem(atPath: outBase + ".json")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: whisperBin)
        var args = [
            "-m", modelPath,
            "-f", rawAudioPath,
            "-of", outBase,
            "--output-json",
            "--language", language,
            "--threads", String(threads),
            "--no-prints",
        ]
        if let prompt, !prompt.isEmpty {
            // 医療用語バイアス (同音異義語抑制)。プロンプト自体は出力に含まれない。
            args.append(contentsOf: ["--prompt", prompt])
        }
        if noGpu {
            // CPU-only。launchd 配下の Metal GPU 初期化デッドロック回避 (HAYABUSA_STT_NO_GPU)。
            args.append("--no-gpu")
        }
        process.arguments = args
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

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(.failed(error: "spawn whisper-cli failed: \(error)", retryable: true))
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

        if timedOut.isSet() {
            return .failure(.failed(error: "whisper-cli timed out after \(timeoutSec)s", retryable: true))
        }
        if process.terminationStatus != 0 {
            let errStr = stderrSink.snapshotString()
            return .failure(.failed(
                error: "whisper exit \(process.terminationStatus): \(errStr.prefix(500))",
                retryable: true
            ))
        }

        let jsonURL = URL(fileURLWithPath: outBase + ".json")
        let parsed: WhisperOutput
        do {
            let data = try Data(contentsOf: jsonURL)
            parsed = try JSONDecoder().decode(WhisperOutput.self, from: data)
        } catch {
            return .failure(.failed(error: "parse whisper output failed: \(error)", retryable: false))
        }

        let fullText = parsed.transcription
            .map { $0.text }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(text: fullText, segmentCount: parsed.transcription.count)
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
