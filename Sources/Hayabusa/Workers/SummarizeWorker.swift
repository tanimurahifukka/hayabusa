// llm.summarize_call worker — STT が edge に保存した transcript を読み、
// Gemma 4 E4B で構造化要約を生成して command-room に返す。
// transcript 本文は payload にも result にも載せない (contracts/openpbx-event-v1 §8)。
// 要約のみが cloud に入り、dataClass に応じた redact は command-room 側で行われる。
//
// 実行モード:
//   1. in-process — HTTP server と同居する起動 (model loaded) ではプロセス内
//      InferenceEngine を直接呼ぶ。自己 HTTP 不要で最速。
//   2. HTTP — dispatcher-only (launchd 配下) では Metal 初期化ができず model を
//      持てないため、GUI セッションで常駐する Hayabusa HTTP server の
//      /v1/chat/completions へ転送する (HAYABUSA_LLM_URL)。
//
// Job payload (command-room apply-stt-result から):
//   {
//     "callRecordId":  "uuid",
//     "workspaceId":   "uuid",
//     "transcriptRef": "edge://<pbxInstanceId>/<uniqueId>",  ← STTWorker が発行
//     "sttKind":       "clinical" | "voicemail",
//     "dataClass":     "medical_sensitive" など (参考情報)
//   }
//
// 返却 (JobResultReport.result):
//   { "summary": "【要旨】…", "model": "...", "sttKind": "...", "elapsedMs": 1234 }
//
// 環境変数:
//   HAYABUSA_STT_TRANSCRIPTS_DIR  (必須) STTWorker と同じ transcript 保存先
//   HAYABUSA_LLM_URL              (任意) in-process engine が無い場合の転送先
//   HAYABUSA_LLM_API_KEY          (任意) 転送先の Bearer token
//   HAYABUSA_SUMMARIZE_TIMEOUT_SEC (任意) 既定 120
//   HAYABUSA_SUMMARIZE_MAX_TOKENS  (任意) 既定 512

import Foundation

public struct SummarizeWorker: Worker {
    public let jobType: String

    private let engine: (any InferenceEngine)?
    private let llmURL: URL?
    private let llmAPIKey: String?
    private let transcriptsDir: String
    private let timeoutSec: Int
    private let maxTokens: Int
    /// プロンプト肥大・コンテキスト溢れ防止。留守電/診察口述は通常数百字。
    private let maxTranscriptChars = 8_000

    init(
        jobType: String = "llm.summarize_call",
        engine: (any InferenceEngine)?,
        llmURL: URL?,
        llmAPIKey: String? = nil,
        transcriptsDir: String,
        timeoutSec: Int = 120,
        maxTokens: Int = 512
    ) {
        self.jobType = jobType
        self.engine = engine
        self.llmURL = llmURL
        self.llmAPIKey = llmAPIKey
        self.transcriptsDir = transcriptsDir
        self.timeoutSec = timeoutSec
        self.maxTokens = maxTokens
    }

    /// env から作る factory。HAYABUSA_STT_TRANSCRIPTS_DIR が無い、または
    /// engine も HAYABUSA_LLM_URL も無い場合は nil (worker 無効)。
    static func fromEnv(
        engine: (any InferenceEngine)?,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> SummarizeWorker? {
        guard let dir = env["HAYABUSA_STT_TRANSCRIPTS_DIR"], !dir.isEmpty else { return nil }
        let llmURL = env["HAYABUSA_LLM_URL"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .flatMap(URL.init(string:))
        guard engine != nil || llmURL != nil else { return nil }
        let timeoutSec = Int(env["HAYABUSA_SUMMARIZE_TIMEOUT_SEC"] ?? "120") ?? 120
        let maxTokens = Int(env["HAYABUSA_SUMMARIZE_MAX_TOKENS"] ?? "512") ?? 512
        return SummarizeWorker(
            engine: engine,
            llmURL: llmURL,
            llmAPIKey: env["HAYABUSA_LLM_API_KEY"].flatMap { $0.isEmpty ? nil : $0 },
            transcriptsDir: dir,
            timeoutSec: timeoutSec,
            maxTokens: maxTokens
        )
    }

    /// App 起動ログ用。
    public var modeDescription: String {
        engine != nil ? "in-process" : "http(\(llmURL?.absoluteString ?? "?"))"
    }

    public func execute(job: JobEnvelope) async -> JobResultReport {
        guard let transcriptRef = job.payload["transcriptRef"]?.stringValue, !transcriptRef.isEmpty else {
            return .failed(error: "missing transcriptRef in payload", retryable: false)
        }
        guard let fileURL = resolveTranscriptRef(transcriptRef) else {
            return .failed(error: "invalid transcriptRef: \(transcriptRef)", retryable: false)
        }
        guard let data = try? Data(contentsOf: fileURL),
              let raw = String(data: data, encoding: .utf8) else {
            return .failed(error: "transcript not found for ref \(transcriptRef)", retryable: false)
        }
        let transcript = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTranscriptChars))
        if transcript.isEmpty {
            return .failed(error: "empty transcript for ref \(transcriptRef)", retryable: false)
        }

        let sttKind = job.payload["sttKind"]?.stringValue ?? "voicemail"
        let prompt = Self.buildPrompt(kind: sttKind, transcript: transcript)
        let messages = [ChatMessage(role: "user", content: prompt)]

        let start = Date()
        let output: String
        let modelLabel: String
        do {
            if let engine {
                let result = try await engine.generate(
                    messages: messages,
                    maxTokens: maxTokens,
                    temperature: 0.2,
                    priority: .low
                )
                output = result.text
                modelLabel = engine.modelDescription
            } else if let llmURL {
                output = try await chatViaHTTP(baseURL: llmURL, messages: messages)
                modelLabel = "http"
            } else {
                return .failed(error: "no inference engine and no HAYABUSA_LLM_URL", retryable: false)
            }
        } catch {
            // 推論失敗は一時障害 (model busy / server down) の可能性が高い。
            return .failed(error: "summarize inference failed: \(error)", retryable: true)
        }

        let summary = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if summary.isEmpty {
            return .failed(error: "model returned empty summary", retryable: true)
        }
        let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)

        return .succeeded(result: .object([
            "summary": .string(summary),
            "model": .string(modelLabel),
            "sttKind": .string(sttKind),
            "elapsedMs": .int(Int64(elapsedMs)),
        ]))
    }

    // MARK: - transcriptRef 解決

    /// "edge://<pbxInstanceId>/<uniqueId>" → <transcriptsDir>/<uniqueId>.txt。
    /// 構成要素は STTWorker.sanitizeRefComponent と同じ文字集合に制限し
    /// path traversal を防ぐ。
    private func resolveTranscriptRef(_ ref: String) -> URL? {
        guard ref.hasPrefix("edge://") else { return nil }
        let path = String(ref.dropFirst("edge://".count))
        guard let last = path.split(separator: "/").last, !last.isEmpty else { return nil }
        let safeId = STTWorker.sanitizeRefComponent(String(last))
        guard safeId == String(last) else { return nil }  // 不正文字を含む ref は拒否
        return URL(fileURLWithPath: transcriptsDir).appendingPathComponent("\(safeId).txt")
    }

    // MARK: - プロンプト

    /// 診察 (clinical) と留守電 (voicemail) の要約プロンプト。本ファイルが唯一の正本。
    /// command-room の WorkerPromptTemplate / settings/prompts UI は要約ワーカーに
    /// 未接続なので、文面変更はここで行い、hayabusa を再ビルド+再デプロイすること。
    static func buildPrompt(kind: String, transcript: String) -> String {
        if kind == "clinical" {
            return """
            以下は診察中の会話の文字起こし（句読点なし）です。
            診療録の補助メモとして、会話で確認できた重要情報を日本語で整理してください。

            文字起こし:
            \(transcript)

            以下の見出しごとに、会話内容を箇条書き（各項目を「- 」で始める）で出力してください。
            - 各項目は1行1要点で簡潔にまとめ、文字起こしの丸写しはしない
            - 診断や断定はせず、会話で実際に述べられた事実のみを記載する
            - 該当する情報がない見出しには「- 不明」と記載する

            【要旨】（診察内容の要点を2〜3項目の箇条書きで）
            【患者名】
            【主訴・処置内容】
            【処方】
            【次回指示】
            【備考】
            """
        }
        return """
        あなたは診療クリニックの受付AIアシスタントです。
        以下は患者または関係者からの留守番電話の文字起こしです。
        重要な情報を日本語で簡潔に整理してください。

        文字起こし:
        \(transcript)

        以下の形式で出力してください（該当する情報がない場合は「不明」と記載）:
        【要旨】（1〜2文で用件を要約）
        【お名前】
        【ご用件】
        【緊急度】低 / 中 / 高
        【折返し希望】あり / なし
        """
    }

    // MARK: - HTTP モード (/v1/chat/completions)

    private func chatViaHTTP(baseURL: URL, messages: [ChatMessage]) async throws -> String {
        struct RequestBody: Codable {
            let model: String
            let messages: [ChatMessage]
            let temperature: Float
            let max_tokens: Int
        }
        struct ResponseBody: Codable {
            struct Choice: Codable {
                struct Message: Codable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }

        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let llmAPIKey {
            req.setValue("Bearer \(llmAPIKey)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONEncoder().encode(RequestBody(
            model: "default", messages: messages, temperature: 0.2, max_tokens: maxTokens))
        req.timeoutInterval = TimeInterval(max(1, timeoutSec))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw WhisperHTTPClient.ClientError.badStatus(code, snippet)
        }
        let parsed = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = parsed.choices.first?.message.content else {
            throw WhisperHTTPClient.ClientError.invalidResponse
        }
        return content
    }
}
