// ノード単位の挙動制限。command-room の Job lease に渡すパラメータと
// ローカルでの dispatch 上限を担う。

import Foundation

public struct NodePolicy: Codable, Sendable {
    /// 同時に走らせる Job の最大数。
    public let maxConcurrentJobs: Int

    /// 受諾する priority のフィルタ（urgent / high / normal / low / realtime / batch）。
    /// 空配列ならすべて。
    public let acceptPriority: [String]

    /// メモリ pressure が以下の値のいずれかになったら lease を一時停止。
    /// 値は MemoryMonitor の pressure 段階に整合する想定（normal / warning / critical / emergency）。
    public let refuseWhenMemoryPressure: [String]

    /// command-room から 1 度に持ち帰る lease の batch サイズ。
    public let leaseBatchSize: Int

    /// lease poll の間隔（秒）。
    public let pollIntervalSeconds: Double

    public init(
        maxConcurrentJobs: Int = 1,
        acceptPriority: [String] = [],
        refuseWhenMemoryPressure: [String] = ["critical", "emergency"],
        leaseBatchSize: Int = 1,
        pollIntervalSeconds: Double = 2.0
    ) {
        self.maxConcurrentJobs = maxConcurrentJobs
        self.acceptPriority = acceptPriority
        self.refuseWhenMemoryPressure = refuseWhenMemoryPressure
        self.leaseBatchSize = leaseBatchSize
        self.pollIntervalSeconds = pollIntervalSeconds
    }

    public func accepts(priority: String) -> Bool {
        if acceptPriority.isEmpty { return true }
        return acceptPriority.contains(priority)
    }
}
