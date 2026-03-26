import Foundation

struct ClusterStatus: Decodable {
    let cluster: Bool
    let routing: String?
    let nodes: [ClusterNode]?
    let bandwidth: [BandwidthSnapshot]?

    var isEnabled: Bool { cluster }
}

struct ClusterNode: Decodable, Identifiable {
    let id: String
    let host: String
    let port: Int
    let backend: String
    let model: String
    let slots: Int
    let isLocal: Bool
    let isHealthy: Bool
    let consecutiveFailures: Int
    let totalMemory: Int64
    let rssBytes: Int64
    let freeMemory: Int64
    let memoryPressure: String

    var displayName: String {
        isLocal ? "Local (\(host):\(port))" : "\(host):\(port)"
    }

    var load: Double {
        guard totalMemory > 0 else { return 0 }
        return Double(rssBytes) / Double(totalMemory)
    }
}

struct BandwidthSnapshot: Decodable, Identifiable {
    let nodeId: String
    let isLocal: Bool
    let ewmaTokPerSec: Double
    let activeRequests: Int
    let totalRequests: Int
    let totalTokens: Int

    var id: String { nodeId }

    var effectiveBandwidth: Double {
        guard activeRequests > 0 else { return ewmaTokPerSec }
        return ewmaTokPerSec / Double(1 + activeRequests)
    }
}
