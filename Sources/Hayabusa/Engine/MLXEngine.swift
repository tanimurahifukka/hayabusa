import Foundation
import MLXLLM
import MLXLMCommon

final class MLXEngine: InferenceEngine, @unchecked Sendable {
    private let modelContainer: ModelContainer
    let modelDescription: String
    let slotCount: Int

    // Slot tracking for diagnostics (protected by lock)
    private let lock = NSLock()
    private var slotStates: [SlotState]
    private var activeCount = 0

    init(modelId: String, slotCount: Int = 4) async throws {
        self.slotCount = slotCount
        self.slotStates = Array(repeating: .idle, count: slotCount)

        let configuration = ModelConfiguration(id: modelId)

        print("[MLX] Downloading/loading model: \(modelId)")
        self.modelContainer = try await LLMModelFactory.shared.loadContainer(
            configuration: configuration,
            progressHandler: { progress in
                if progress.fractionCompleted < 1.0 {
                    print("[MLX] Progress: \(Int(progress.fractionCompleted * 100))%")
                }
            }
        )
        self.modelDescription = "MLX \(modelId)"
        print("[MLX] Model loaded successfully")
    }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Float,
        priority: SlotPriority
    ) async throws -> GenerationResult {
        // Track slot state for diagnostics
        let slotIndex = acquireSlotIndex()
        guard let slotIndex else {
            throw HayabusaError.noSlotsAvailable
        }
        defer { releaseSlotIndex(slotIndex) }

        // Convert ChatMessage to MLX message format
        let mlxMessages: [[String: String]] = messages.map {
            ["role": $0.role, "content": $0.content]
        }

        // Prepare input using chat template
        let userInput = UserInput(messages: mlxMessages)

        setSlotState(slotIndex, .promptEval)
        let lmInput = try await modelContainer.prepare(input: userInput)

        // Generate
        setSlotState(slotIndex, .generating)
        let parameters = GenerateParameters(
            maxTokens: maxTokens,
            temperature: temperature
        )

        let stream = try await modelContainer.generate(
            input: lmInput,
            parameters: parameters
        )

        var text = ""
        var promptTokens = 0
        var completionTokens = 0

        for try await generation in stream {
            switch generation {
            case .chunk(let chunk):
                text += chunk
            case .info(let info):
                promptTokens = info.promptTokenCount
                completionTokens = info.generationTokenCount
            case .toolCall:
                break
            }
        }

        return GenerationResult(
            text: text,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }

    func slotSummary() -> [(index: Int, state: String, priority: String, pos: Int32)] {
        lock.lock()
        let states = slotStates
        lock.unlock()
        return states.enumerated().map { (i, state) in
            (index: i, state: state.rawValue, priority: "low", pos: 0)
        }
    }

    // MARK: - Slot tracking

    private func acquireSlotIndex() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = slotStates.firstIndex(of: .idle) else {
            return nil
        }
        slotStates[idx] = .promptEval
        activeCount += 1
        return idx
    }

    private func releaseSlotIndex(_ index: Int) {
        lock.lock()
        slotStates[index] = .idle
        activeCount -= 1
        lock.unlock()
    }

    private func setSlotState(_ index: Int, _ state: SlotState) {
        lock.lock()
        slotStates[index] = state
        lock.unlock()
    }
}
