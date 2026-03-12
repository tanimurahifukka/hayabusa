import Foundation

struct ChatResponse: Encodable, Sendable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
    let usage: Usage

    struct Choice: Encodable, Sendable {
        let index: Int
        let message: ResponseMessage
        let finish_reason: String
    }

    struct ResponseMessage: Encodable, Sendable {
        let role: String
        let content: String
    }

    struct Usage: Encodable, Sendable {
        let prompt_tokens: Int
        let completion_tokens: Int
        let total_tokens: Int
    }

    init(id: String, model: String, content: String, promptTokens: Int, completionTokens: Int) {
        self.id = id
        self.object = "chat.completion"
        self.created = Int(Date().timeIntervalSince1970)
        self.model = model
        self.choices = [
            Choice(
                index: 0,
                message: ResponseMessage(role: "assistant", content: content),
                finish_reason: "stop"
            )
        ]
        self.usage = Usage(
            prompt_tokens: promptTokens,
            completion_tokens: completionTokens,
            total_tokens: promptTokens + completionTokens
        )
    }
}
