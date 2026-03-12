protocol InferenceEngine: Sendable {
    var modelDescription: String { get }
    var slotCount: Int { get }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Float,
        priority: SlotPriority
    ) async throws -> GenerationResult

    func slotSummary() -> [(index: Int, state: String, priority: String, pos: Int32)]
}
