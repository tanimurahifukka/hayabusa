import Foundation

// MLX backend is currently disabled pending mlx-swift-lm 0.2x+ API migration.
// init always throws HayabusaError.modelLoadFailed; no instance is ever created.
// Use --backend llama (default) or --dispatcher-only instead.
// See: Package.swift comment, README, and Roadmap.

final class MLXEngine: InferenceEngine, @unchecked Sendable {
    // Stored properties required for InferenceEngine protocol conformance.
    // These are never initialized because init always throws before reaching
    // any self.* assignment.
    let modelDescription: String
    var slotCount: Int
    let layerSkipConfig: LayerSkipConfig?

    init(modelId: String, slotCount: Int = 4, maxMemoryGB: Double? = nil, maxContext: Int? = nil,
         layerSkipConfig: LayerSkipConfig? = nil) async throws {
        // MLX backend is disabled: mlx-swift-lm 0.2x+ API needs migration.
        // Downloader and TokenizerLoader are now required; old loadContainer API removed.
        // Migration is tracked for a future PR; use --backend llama or --dispatcher-only.
        throw HayabusaError.modelLoadFailed(
            "MLX backend currently disabled (mlx-swift-lm 0.2x+ API needs migration; use --backend llama or --dispatcher-only)"
        )
    }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Float,
        priority: SlotPriority
    ) async throws -> GenerationResult {
        // Unreachable: init always throws, so no MLXEngine instance is ever created.
        fatalError("MLXEngine.generate called on disabled backend")
    }

    func slotSummary() -> [(index: Int, state: String, priority: String, pos: Int32)] {
        // Unreachable: init always throws, so no MLXEngine instance is ever created.
        fatalError("MLXEngine.slotSummary called on disabled backend")
    }

    func collectGenome(config: GenomeConfig) async throws {
        // Unreachable: init always throws, so no MLXEngine instance is ever created.
        fatalError("MLXEngine.collectGenome called on disabled backend")
    }

    func memoryInfo() -> EngineMemoryInfo? {
        // Unreachable: init always throws, so no MLXEngine instance is ever created.
        fatalError("MLXEngine.memoryInfo called on disabled backend")
    }
}
