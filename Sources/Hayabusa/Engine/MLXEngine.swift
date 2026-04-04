import Foundation
import MLX
import MLXLLM
import MLXLMCommon

final class MLXEngine: InferenceEngine, @unchecked Sendable {
    private let modelContainer: ModelContainer
    private let scheduler: MLXBatchScheduler
    private let memoryMonitor: MemoryMonitor
    let modelDescription: String
    private let initialSlotCount: Int
    let layerSkipConfig: LayerSkipConfig?

    var slotCount: Int { scheduler.currentSlotCount }

    init(modelId: String, slotCount: Int = 4, maxMemoryGB: Double? = nil, maxContext: Int? = nil,
         layerSkipConfig: LayerSkipConfig? = nil) async throws {
        self.initialSlotCount = slotCount

        // Register Gemma 4 model types (not yet in upstream mlx-swift-lm)
        Self.registerGemma4ModelTypes()

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

        // Apply memory limits after model load
        if let gb = maxMemoryGB {
            let bytes = Int(gb * 1024 * 1024 * 1024)
            Memory.memoryLimit = bytes
            Memory.cacheLimit = min(256 * 1024 * 1024, bytes / 10)
            Memory.clearCache()
            print("[MLX] Memory limit: \(gb)GB, cache limit: \(min(256, Int(gb * 1024) / 10))MB")
        }
        if let ctx = maxContext {
            print("[MLX] Max KV context: \(ctx)")
        }

        // Apply layer skipping before creating scheduler
        self.layerSkipConfig = layerSkipConfig
        if let config = layerSkipConfig {
            await config.apply(to: modelContainer)
        }

        self.modelDescription = "MLX \(modelId)"
        self.scheduler = MLXBatchScheduler(modelContainer: modelContainer, slotCount: slotCount, maxContext: maxContext)

        // Set up memory monitor with dynamic slot adjustment
        let sched = self.scheduler
        self.memoryMonitor = MemoryMonitor(activeSlots: { [weak sched] in
            sched?.activeSlotCount ?? 0
        })

        let initSlots = slotCount
        self.memoryMonitor.onPressureChange = { [weak sched] pressure, info in
            guard let sched else { return }
            let current = sched.currentSlotCount

            switch pressure {
            case .normal:
                // Free > 4GB: can grow back toward initial count (or +1)
                if current < initSlots {
                    sched.adjustSlots(to: current + 1)
                }
            case .low:
                // 2-4GB free: hold steady, no changes
                break
            case .critical:
                // 1-2GB free: reduce by 1 slot
                if current > MLXBatchScheduler.minimumSlots {
                    sched.adjustSlots(to: current - 1)
                }
                Memory.clearCache()
            case .emergency:
                // < 1GB free: emergency — drop to minimum + clear cache
                sched.adjustSlots(to: MLXBatchScheduler.minimumSlots)
                Memory.clearCache()
                print("[MLX] EMERGENCY: memory critically low, forced to \(MLXBatchScheduler.minimumSlots) slot(s)")
            }
        }

        self.memoryMonitor.start()
        print("[MLX] Model loaded successfully (batch scheduler + memory monitor active)")
    }

    func generate(
        messages: [ChatMessage],
        maxTokens: Int,
        temperature: Float,
        priority: SlotPriority
    ) async throws -> GenerationResult {
        let mlxMessages: [[String: String]] = messages.map {
            ["role": $0.role, "content": $0.content]
        }

        return try await withCheckedThrowingContinuation { continuation in
            let job = MLXGenerationJob(
                messages: mlxMessages,
                maxTokens: maxTokens,
                temperature: temperature,
                priority: priority,
                continuation: continuation
            )
            scheduler.submit(job)
        }
    }

    func slotSummary() -> [(index: Int, state: String, priority: String, pos: Int32)] {
        scheduler.slotSummary()
    }

    func collectGenome(config: GenomeConfig) async throws {
        try await GenomeCollector.collect(
            from: modelContainer,
            modelName: modelDescription,
            config: config
        )
    }

    func memoryInfo() -> EngineMemoryInfo? {
        let info = memoryMonitor.latestInfo
        let pressure = memoryMonitor.currentPressure
        return EngineMemoryInfo(
            totalPhysical: info.totalPhysical,
            rssBytes: info.rssBytes,
            freeEstimate: info.freeEstimate,
            activeSlots: info.activeSlots,
            pressure: pressure.rawValue
        )
    }

    // MARK: - Gemma 4 Model Registration

    private static var gemma4Registered = false

    private static func registerGemma4ModelTypes() {
        guard !gemma4Registered else { return }
        gemma4Registered = true

        let creator: @Sendable (Data) throws -> any LanguageModel = { data in
            let config = try JSONDecoder().decode(Gemma4TextConfiguration.self, from: data)
            return Gemma4TextModel(config)
        }

        Task {
            await LLMTypeRegistry.shared.registerModelType("gemma4", creator: creator)
            await LLMTypeRegistry.shared.registerModelType("gemma4_text", creator: creator)
        }
        // Small delay to ensure registration completes before model load
        Thread.sleep(forTimeInterval: 0.1)
        print("[MLX] Registered Gemma 4 model types (gemma4, gemma4_text)")
    }
}
