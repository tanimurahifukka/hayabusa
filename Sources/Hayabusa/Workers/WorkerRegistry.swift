// jobType → Worker のマッピング。NodeConfig.capabilities に書かれた jobType と
// 実装の Worker を結びつける。NodeConfig が要求する jobType に対応する Worker が
// 揃っていない場合は dispatcher 起動を拒否する。

import Foundation

public final class WorkerRegistry: @unchecked Sendable {
    private var workers: [String: any Worker] = [:]

    public init() {}

    public func register(_ worker: any Worker) {
        workers[worker.jobType] = worker
    }

    public func resolve(_ jobType: String) -> (any Worker)? {
        workers[jobType]
    }

    public var registeredJobTypes: [String] { Array(workers.keys).sorted() }

    /// capability で要求する jobType すべてが解決可能か確認。欠けているものを返す。
    public func missing(forCapability capability: NodeCapability) -> [String] {
        capability.jobTypes.filter { workers[$0] == nil }
    }
}
