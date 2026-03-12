struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String
}

struct ChatRequest: Decodable, Sendable {
    let messages: [ChatMessage]
    let model: String?
    let max_tokens: Int?
    let temperature: Float?
    let priority: String?
}
