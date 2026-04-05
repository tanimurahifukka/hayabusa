// UzuHealthMonitor.swift — 子ノード死活監視

import Foundation

/// 定期的に子ノードの/healthを叩いて死活監視
final class UzuHealthMonitor: @unchecked Sendable {
    let orchestrator: UzuOrchestrator
    let interval: TimeInterval
    private var isRunning = false

    init(orchestrator: UzuOrchestrator, interval: TimeInterval = 10.0) {
        self.orchestrator = orchestrator
        self.interval = interval
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        Task {
            while isRunning {
                await checkAllNodes()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        print("[UzuHealth] 死活監視開始 (interval: \(Int(interval))s)")
    }

    func stop() {
        isRunning = false
        print("[UzuHealth] 死活監視停止")
    }

    private func checkAllNodes() async {
        let nodes = orchestrator.allNodes()
        for node in nodes {
            let healthy = await checkHealth(node)
            if !healthy {
                var updated = node
                updated.isHealthy = false
                orchestrator.registerNode(updated)  // 状態更新

                if node.isHealthy {
                    // 以前は健全だったが落ちた
                    print("[UzuHealth] Node DOWN: \(node.id) (\(node.model))")
                }
            } else if !node.isHealthy {
                // 復旧
                var updated = node
                updated.isHealthy = true
                updated.lastSeen = Date()
                orchestrator.registerNode(updated)
                print("[UzuHealth] Node RECOVERED: \(node.id)")
            }
        }
    }

    private func checkHealth(_ node: UzuNode) async -> Bool {
        let url = URL(string: "\(node.baseURL)/health")!
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let body = String(data: data, encoding: .utf8) ?? ""
            return body.contains("ok")
        } catch {
            return false
        }
    }
}
