// whisper-server (whisper.cpp examples/server) への HTTP クライアント。
//
// STTWorker の常駐モード用: ジョブ毎に whisper-cli を spawn するとモデルロード
// (数秒) が毎回発生し、launchd 配下では Metal 初期化デッドロック回避のため
// CPU 推論を強いられる。whisper-server を GUI セッションの LaunchAgent として
// 常駐させ (config/com.tanimura.whisper-server.plist)、本クライアントから
// multipart POST することで「モデル常駐 + Metal GPU」の両方を得る。
//
// whisper.cpp を SwiftPM library として直接リンクする案は、本体が既に
// llama.cpp の ggml をリンクしておりシンボル衝突リスクが高いため不採用。
//
// API (examples/server):
//   GET  /health     — モデルロード完了で 200
//   POST /inference  — multipart/form-data: file, prompt, temperature,
//                      response_format=json → {"text": "..."}
//   音声は miniaudio が内部で 16kHz に変換するため 8kHz 電話 WAV を直送できる。

import Foundation

public struct WhisperHTTPClient: Sendable {
    public enum ClientError: Error, CustomStringConvertible {
        case badStatus(Int, String)
        case invalidResponse
        case serverError(String)

        public var description: String {
            switch self {
            case .badStatus(let code, let body): return "whisper-server HTTP \(code): \(body)"
            case .invalidResponse: return "whisper-server returned unparsable response"
            case .serverError(let msg): return "whisper-server error: \(msg)"
            }
        }
    }

    private let baseURL: URL
    private let timeoutSec: Int

    public init(baseURL: URL, timeoutSec: Int = 300) {
        self.baseURL = baseURL
        self.timeoutSec = timeoutSec
    }

    /// モデルロード完了確認。常駐サーバが落ちていれば false (呼び出し側で cli へフォールバック)。
    public func isHealthy() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    /// /inference へ multipart POST して文字起こしテキストを返す。
    public func transcribe(audioPath: String, prompt: String?) async throws -> String {
        let boundary = "----hayabusa-stt-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append(Data((
                "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
                + "\(value)\r\n"
            ).utf8))
        }

        appendField("response_format", "json")
        appendField("temperature", "0.0")
        if let prompt, !prompt.isEmpty {
            appendField("prompt", prompt)
        }

        let audioData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
        let fileName = (audioPath as NSString).lastPathComponent
        body.append(Data((
            "--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
            + "Content-Type: application/octet-stream\r\n\r\n"
        ).utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: baseURL.appendingPathComponent("inference"))
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = TimeInterval(max(1, timeoutSec))

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ClientError.invalidResponse
        }
        guard http.statusCode == 200 else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw ClientError.badStatus(http.statusCode, snippet)
        }

        struct InferenceResponse: Codable {
            let text: String?
            let error: String?
        }
        guard let parsed = try? JSONDecoder().decode(InferenceResponse.self, from: data) else {
            throw ClientError.invalidResponse
        }
        if let error = parsed.error {
            throw ClientError.serverError(error)
        }
        guard let text = parsed.text else {
            throw ClientError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
