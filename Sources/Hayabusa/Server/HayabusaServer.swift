import Foundation
import Hummingbird

struct HayabusaServer {
    let engine: any InferenceEngine
    let port: Int

    func run() async throws {
        let router = Router()
        let engine = self.engine

        // GET /health
        router.get("health") { _, _ -> String in
            "{\"status\":\"ok\"}"
        }

        // POST /v1/chat/completions
        router.post("v1/chat/completions") { request, context in
            let chatRequest = try await context.requestDecoder.decode(
                ChatRequest.self, from: request, context: context
            )

            let result = try await engine.generate(
                messages: chatRequest.messages,
                maxTokens: chatRequest.max_tokens ?? 2048,
                temperature: chatRequest.temperature ?? 0.7,
                priority: SlotPriority(string: chatRequest.priority)
            )

            let response = ChatResponse(
                id: "hayabusa-\(UUID().uuidString.prefix(8))",
                model: chatRequest.model ?? "local",
                content: result.text,
                promptTokens: result.promptTokens,
                completionTokens: result.completionTokens
            )

            let jsonData = try JSONEncoder().encode(response)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            return jsonString
        }

        // GET /slots — diagnostic endpoint
        router.get("slots") { _, _ -> String in
            let summary = engine.slotSummary()
            let slots = summary.map { slot in
                "{\"index\":\(slot.index),\"state\":\"\(slot.state)\",\"priority\":\"\(slot.priority)\",\"pos\":\(slot.pos)}"
            }
            return "[\(slots.joined(separator: ","))]"
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port))
        )
        try await app.runService()
    }
}
