// hayabusa 側 dispatcher。
//
// loop:
//   1. JobLeaseClient.lease で N 件取得
//   2. 各 job を WorkerRegistry で resolve → Worker.execute
//   3. 結果を JobLeaseClient.reportResult で送信
//   4. 失敗時は retryable フラグ付きで failed を送る
//
// 並列度は NodePolicy.maxConcurrentJobs に従う（簡易: semaphore で抑える）。
// メモリ pressure 監視 (MemoryMonitor) との接続は後続 PR。

import Foundation

public actor JobDispatcher {
    private let config: NodeConfig
    private let client: JobLeaseClient
    private let registry: WorkerRegistry
    private var running = false
    private var task: Task<Void, Never>?

    public init(config: NodeConfig, client: JobLeaseClient, registry: WorkerRegistry) {
        self.config = config
        self.client = client
        self.registry = registry
    }

    public func start() {
        guard !running else { return }
        let missing = registry.missing(forCapability: config.capabilities)
        if !missing.isEmpty {
            let msg = "[Hayabusa] dispatcher refused: missing workers for jobTypes: \(missing.joined(separator: ", "))\n"
            FileHandle.standardError.write(Data(msg.utf8))
            return
        }
        running = true
        let intervalNanos = UInt64(max(0.25, config.policy.pollIntervalSeconds) * 1_000_000_000)
        let cfg = config
        let cli = client
        let reg = registry
        task = Task.detached(priority: .background) {
            while await JobDispatcher.isRunning(self) {
                await JobDispatcher.tick(config: cfg, client: cli, registry: reg)
                try? await Task.sleep(nanoseconds: intervalNanos)
            }
        }
    }

    public func stop() {
        running = false
        task?.cancel()
        task = nil
    }

    private static func isRunning(_ self_: JobDispatcher) async -> Bool {
        await self_.running
    }

    // 1 tick: lease → execute → report
    public static func tick(config: NodeConfig, client: JobLeaseClient, registry: WorkerRegistry) async {
        let req = LeaseRequest(
            limit: config.policy.leaseBatchSize,
            jobTypes: config.capabilities.jobTypes.isEmpty ? nil : config.capabilities.jobTypes
        )
        let response: LeaseResponse
        do {
            response = try await client.lease(request: req)
        } catch {
            FileHandle.standardError.write(Data("[Hayabusa] lease error: \(error)\n".utf8))
            return
        }
        if response.jobs.isEmpty { return }

        // 並列実行は maxConcurrentJobs で抑える。
        let limit = max(1, config.policy.maxConcurrentJobs)
        var idx = 0
        while idx < response.jobs.count {
            let batchEnd = min(idx + limit, response.jobs.count)
            let batch = Array(response.jobs[idx..<batchEnd])
            idx = batchEnd

            await withTaskGroup(of: Void.self) { group in
                for env in batch {
                    if !config.policy.accepts(priority: env.priority) {
                        let report = JobResultReport.failed(error: "priority \(env.priority) refused by policy", retryable: true)
                        group.addTask { await Self.report(client: client, jobId: env.jobId, report: report) }
                        continue
                    }
                    guard let worker = registry.resolve(env.jobType) else {
                        let report = JobResultReport.failed(error: "no worker for jobType \(env.jobType)", retryable: false)
                        group.addTask { await Self.report(client: client, jobId: env.jobId, report: report) }
                        continue
                    }
                    group.addTask {
                        let report = await worker.execute(job: env)
                        await Self.report(client: client, jobId: env.jobId, report: report)
                    }
                }
            }
        }
    }

    private static func report(client: JobLeaseClient, jobId: String, report: JobResultReport) async {
        do {
            _ = try await client.reportResult(jobId: jobId, report: report)
        } catch {
            FileHandle.standardError.write(Data("[Hayabusa] result report error for \(jobId): \(error)\n".utf8))
        }
    }
}
