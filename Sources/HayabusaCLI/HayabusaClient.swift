// HayabusaClient.swift — Hayabusaサーバーへの軽量HTTPクライアント
// モデルをロードしない。URLSessionのみ使用。

import Foundation

struct HayabusaClient {
    let baseURL: String

    init(port: Int = 8080) {
        self.baseURL = "http://127.0.0.1:\(port)"
    }

    // MARK: - Health Check

    func health() async throws -> Bool {
        let url = URL(string: "\(baseURL)/health")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return body.contains("ok")
    }

    func ensureServerRunning() async throws {
        do {
            let ok = try await health()
            guard ok else { throw ClientError.serverNotRunning }
        } catch {
            throw ClientError.serverNotRunning
        }
    }

    // MARK: - Chat Completions

    func chatCompletion(
        messages: [[String: String]],
        maxTokens: Int = 2048,
        temperature: Float = 0.0,
        stream: Bool = false
    ) async throws -> ChatCompletionResponse {
        let url = URL(string: "\(baseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": "local",
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": stream,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw ClientError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
        }

        return try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
    }

    // MARK: - Convenience

    func ask(systemPrompt: String, userPrompt: String, maxTokens: Int = 2048) async throws -> String {
        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": userPrompt],
        ]
        let response = try await chatCompletion(messages: messages, maxTokens: maxTokens, temperature: 0.0)
        return response.choices.first?.message.content ?? ""
    }

    // MARK: - Server Management

    func slots() async throws -> String {
        let url = URL(string: "\(baseURL)/slots")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

// MARK: - Response Types

struct ChatCompletionResponse: Codable {
    let id: String
    let model: String
    let choices: [Choice]
    let usage: Usage?

    struct Choice: Codable {
        let message: Message
        let finish_reason: String?

        struct Message: Codable {
            let role: String
            let content: String
        }
    }

    struct Usage: Codable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
    }
}

// MARK: - Errors

enum ClientError: Error, CustomStringConvertible {
    case serverNotRunning
    case httpError(statusCode: Int, body: String)
    case invalidResponse(String)

    var description: String {
        switch self {
        case .serverNotRunning:
            return """
            Hayabusaサーバーが起動していません。

            起動方法:
              hayabusa server start
            または:
              .build/release/Hayabusa models/model.gguf &
            """
        case .httpError(let code, let body):
            return "HTTP \(code): \(body)"
        case .invalidResponse(let msg):
            return "Invalid response: \(msg)"
        }
    }
}
