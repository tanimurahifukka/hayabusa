import Foundation

actor APIClient {
    private var baseURL: URL

    init(port: Int = 8080) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    func updatePort(_ port: Int) {
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    // MARK: - Health

    func health() async throws -> Bool {
        let url = baseURL.appendingPathComponent("health")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["status"] as? String == "ok"
    }

    // MARK: - Slots

    func slots() async throws -> [SlotInfo] {
        let url = baseURL.appendingPathComponent("slots")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([SlotInfo].self, from: data)
    }

    // MARK: - Memory

    func memory() async throws -> MemoryInfo {
        let url = baseURL.appendingPathComponent("v1/memory")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(MemoryInfo.self, from: data)
    }

    // MARK: - Cluster Status

    func clusterStatus() async throws -> ClusterStatus {
        let url = baseURL.appendingPathComponent("v1/cluster/status")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(ClusterStatus.self, from: data)
    }

    // MARK: - Chat Completion

    func chatCompletion(messages: [[String: String]], maxTokens: Int = 2048, temperature: Double = 0.7) async throws -> ChatResponse {
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        let body: [String: Any] = [
            "messages": messages,
            "max_tokens": maxTokens,
            "temperature": temperature,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown"
            throw APIError.serverError(statusCode: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "empty"
            throw APIError.decodeFailed(raw: raw, underlying: error)
        }
    }

    enum APIError: LocalizedError {
        case serverError(statusCode: Int, body: String)
        case decodeFailed(raw: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .serverError(let code, let body):
                return "Server error \(code): \(body)"
            case .decodeFailed(let raw, let err):
                return "Decode error: \(err.localizedDescription)\nRaw: \(raw.prefix(500))"
            }
        }
    }
}
