import Foundation
import Hummingbird

struct HayabusaServer {
    let engine: any InferenceEngine
    let port: Int
    let bindAddress: String
    let clusterManager: ClusterManager?
    let speculativeDecoder: SpeculativeDecoder?
    let kvQuantizeMode: KVQuantizeMode
    let layerSkipConfig: LayerSkipConfig?

    init(
        engine: any InferenceEngine,
        port: Int,
        bindAddress: String = "127.0.0.1",
        clusterManager: ClusterManager? = nil,
        speculativeDecoder: SpeculativeDecoder? = nil,
        kvQuantizeMode: KVQuantizeMode = .off,
        layerSkipConfig: LayerSkipConfig? = nil
    ) {
        self.engine = engine
        self.port = port
        self.bindAddress = bindAddress
        self.clusterManager = clusterManager
        self.speculativeDecoder = speculativeDecoder
        self.kvQuantizeMode = kvQuantizeMode
        self.layerSkipConfig = layerSkipConfig
    }

    func run() async throws {
        let router = Router()
        let engine = self.engine
        let clusterManager = self.clusterManager
        let speculativeDecoder = self.speculativeDecoder
        let kvQuantizeMode = self.kvQuantizeMode
        let layerSkipConfig = self.layerSkipConfig

        // GET /health  — Codable + application/json
        router.get("health") { _, _ -> Response in
            try jsonResponse(HealthResponse(status: "ok"))
        }

        // POST /v1/chat/completions — Codable + application/json
        router.post("v1/chat/completions") { request, context -> Response in
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
            return try jsonResponse(response)
        }

        // GET /slots — diagnostic endpoint (Codable)
        router.get("slots") { _, _ -> Response in
            let summary = engine.slotSummary()
            let slots = summary.map { slot in
                SlotInfoResponse(
                    index: slot.index,
                    state: slot.state,
                    priority: slot.priority,
                    pos: slot.pos
                )
            }
            return try jsonResponse(slots)
        }

        // GET /v1/memory — memory status (Codable)
        router.get("v1/memory") { _, _ -> Response in
            guard let info = engine.memoryInfo() else {
                return try jsonResponse(MemoryStatusResponse.unknown)
            }
            return try jsonResponse(
                MemoryStatusResponse(
                    totalPhysical: info.totalPhysical,
                    rssBytes: info.rssBytes,
                    freeEstimate: info.freeEstimate,
                    activeSlots: info.activeSlots,
                    pressure: info.pressure,
                    slots: engine.slotCount
                )
            )
        }

        // GET /v1/cluster/status — cluster node listing with memory info (Codable)
        router.get("v1/cluster/status") { _, _ -> Response in
            // Update local node memory before responding
            if let cm = clusterManager, let info = engine.memoryInfo() {
                cm.updateLocalMemory(info)
            }

            guard let cm = clusterManager else {
                return try jsonResponse(ClusterStatusResponse.singleNode)
            }

            let nodes = cm.allNodes().map { node in
                ClusterNodeView(
                    id: node.id,
                    host: node.host,
                    port: node.port,
                    backend: node.backend,
                    model: node.model,
                    slots: node.slots,
                    isLocal: node.isLocal,
                    isHealthy: node.isHealthy,
                    consecutiveFailures: node.consecutiveFailures,
                    totalMemory: node.totalMemory,
                    rssBytes: node.rssBytes,
                    freeMemory: node.freeMemory,
                    memoryPressure: node.memoryPressure
                )
            }
            let bandwidth = cm.bandwidthSnapshots().map { s in
                BandwidthView(
                    nodeId: s.nodeId,
                    isLocal: s.isLocal,
                    ewmaTokPerSec: s.ewmaTokPerSec,
                    activeRequests: s.activeRequests,
                    totalRequests: s.totalRequests,
                    totalTokens: s.totalTokens
                )
            }
            return try jsonResponse(
                ClusterStatusResponse(
                    cluster: true,
                    routing: "uzu",
                    nodes: nodes,
                    bandwidth: bandwidth
                )
            )
        }

        // GET /v1/stats — speculative decoding & KV quantization metrics (Codable)
        router.get("v1/stats") { _, _ -> Response in
            // Speculative decoding metrics
            let speculative: SpeculativeStats = {
                guard let sd = speculativeDecoder else { return .disabled }
                let m = sd.metrics
                let effective = m.totalGenerations > 0
                    ? Double(m.totalCompletionTokens) / Double(m.totalGenerations)
                    : 0
                return SpeculativeStats(
                    enabled: true,
                    speculativeTokens: 4,
                    totalDraftTokens: m.totalDraftTokens,
                    acceptedTokens: m.acceptedTokens,
                    acceptanceRate: m.acceptanceRate,
                    totalGenerations: m.totalGenerations,
                    totalCompletionTokens: m.totalCompletionTokens,
                    effectiveTokPerSec: effective
                )
            }()

            let kv = KvQuantizeStats(
                enabled: kvQuantizeMode != .off,
                mode: kvQuantizeMode.rawValue,
                description: kvQuantizeMode.description
            )

            let layerSkip: LayerSkipStats =
                layerSkipConfig?.statsView ?? .disabled

            let memory: MemoryStats? = engine.memoryInfo().map { info in
                MemoryStats(
                    totalPhysical: info.totalPhysical,
                    rssBytes: info.rssBytes,
                    freeEstimate: info.freeEstimate,
                    pressure: info.pressure
                )
            }

            return try jsonResponse(
                StatsResponse(
                    speculative: speculative,
                    kvQuantize: kv,
                    layerSkip: layerSkip,
                    memory: memory
                )
            )
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(bindAddress, port: port))
        )
        try await app.runService()
    }
}
