import Foundation

// Diagnostic endpoint 用の Encodable response 型。
// 元は HayabusaServer.swift 内で文字列補間で組み立てていたが、
// content-type を JSON 化するため Codable + jsonResponse に置換。

// MARK: - /slots

struct SlotInfoResponse: Encodable, Sendable {
    let index: Int
    let state: String
    let priority: String
    let pos: Int32
}

// MARK: - /v1/memory

struct MemoryStatusResponse: Encodable, Sendable {
    let totalPhysical: UInt64?
    let rssBytes: UInt64?
    let freeEstimate: UInt64?
    let activeSlots: Int?
    let pressure: String
    let slots: Int?

    /// engine.memoryInfo() が nil の時 (= backend が memory 情報を提供しない) のフォールバック
    static let unknown = MemoryStatusResponse(
        totalPhysical: nil,
        rssBytes: nil,
        freeEstimate: nil,
        activeSlots: nil,
        pressure: "unknown",
        slots: nil
    )
}

// MARK: - /v1/cluster/status

struct ClusterStatusResponse: Encodable, Sendable {
    let cluster: Bool
    let routing: String?
    let nodes: [ClusterNodeView]?
    let bandwidth: [BandwidthView]?

    /// clusterManager==nil のときに返す single-node form
    static let singleNode = ClusterStatusResponse(
        cluster: false,
        routing: nil,
        nodes: nil,
        bandwidth: nil
    )
}

struct ClusterNodeView: Encodable, Sendable {
    let id: String
    let host: String
    let port: Int
    let backend: String
    let model: String
    let slots: Int
    let isLocal: Bool
    let isHealthy: Bool
    let consecutiveFailures: Int
    let totalMemory: UInt64
    let rssBytes: UInt64
    let freeMemory: UInt64
    let memoryPressure: String
}

struct BandwidthView: Encodable, Sendable {
    let nodeId: String
    let isLocal: Bool
    let ewmaTokPerSec: Double
    let activeRequests: Int
    let totalRequests: Int
    let totalTokens: Int
}

// MARK: - /v1/stats

struct StatsResponse: Encodable, Sendable {
    let speculative: SpeculativeStats
    let kvQuantize: KvQuantizeStats
    let layerSkip: LayerSkipStats
    let memory: MemoryStats?
}

struct SpeculativeStats: Encodable, Sendable {
    let enabled: Bool
    let speculativeTokens: Int?
    let totalDraftTokens: Int?
    let acceptedTokens: Int?
    let acceptanceRate: Double?
    let totalGenerations: Int?
    let totalCompletionTokens: Int?
    let effectiveTokPerSec: Double?

    static let disabled = SpeculativeStats(
        enabled: false,
        speculativeTokens: nil,
        totalDraftTokens: nil,
        acceptedTokens: nil,
        acceptanceRate: nil,
        totalGenerations: nil,
        totalCompletionTokens: nil,
        effectiveTokPerSec: nil
    )
}

struct KvQuantizeStats: Encodable, Sendable {
    let enabled: Bool
    let mode: String
    let description: String
}

struct LayerSkipStats: Encodable, Sendable {
    let enabled: Bool
    let threshold: Double?
    let task: String?
    let totalLayers: Int?
    let skippedLayers: Int?
    let skippedIndices: [Int]?

    static let disabled = LayerSkipStats(
        enabled: false,
        threshold: nil,
        task: nil,
        totalLayers: nil,
        skippedLayers: nil,
        skippedIndices: nil
    )
}

struct MemoryStats: Encodable, Sendable {
    let totalPhysical: UInt64
    let rssBytes: UInt64
    let freeEstimate: UInt64
    let pressure: String
}
