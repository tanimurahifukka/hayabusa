import Foundation
import CLlama

enum JobPhase {
    case pendingPromptEval
    case promptEval
    case generating
    case finished
    case failed
}

final class GenerationJob: @unchecked Sendable {
    let promptTokens: [llama_token]
    let maxTokens: Int
    let temperature: Float
    let priority: SlotPriority
    let continuation: CheckedContinuation<GenerationResult, Error>

    var phase: JobPhase = .pendingPromptEval
    var slotHandle: SlotHandle?
    var sampler: UnsafeMutablePointer<llama_sampler>?
    var outputTokens: [llama_token] = []
    var currentPos: Int32 = 0
    var promptEvalOffset: Int = 0     // chunked prompt eval progress

    init(
        promptTokens: [llama_token],
        maxTokens: Int,
        temperature: Float,
        priority: SlotPriority,
        continuation: CheckedContinuation<GenerationResult, Error>
    ) {
        self.promptTokens = promptTokens
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.priority = priority
        self.continuation = continuation
    }

    func complete(text: String) {
        phase = .finished
        continuation.resume(returning: GenerationResult(
            text: text,
            promptTokens: promptTokens.count,
            completionTokens: outputTokens.count
        ))
    }

    func fail(error: Error) {
        phase = .failed
        continuation.resume(throwing: error)
    }
}
