// UzuDiscovery.swift — Bonjour自動検出（_hayabusa._tcp）+ 手動登録

import Foundation

/// Uzuノード登録プロトコル（Bonjourと手動の両方に対応）
final class UzuDiscovery: @unchecked Sendable {
    let orchestrator: UzuOrchestrator

    init(orchestrator: UzuOrchestrator) {
        self.orchestrator = orchestrator
    }

    /// 手動でノードを登録（環境変数 or CLI引数から）
    func registerManual(host: String, port: Int, genres: [String], model: String, backend: String = "mlx", slots: Int = 4) {
        let nodeId = "\(host):\(port)"
        let node = UzuNode(
            id: nodeId,
            host: host,
            port: port,
            genres: genres,
            model: model,
            backend: backend,
            slots: slots,
            isHealthy: true,
            lastSeen: Date(),
            elo: Dictionary(uniqueKeysWithValues: genres.map { ($0, 1500) })
        )
        orchestrator.registerNode(node)
    }

    /// 環境変数からノード情報を読み取って登録
    /// HAYABUSA_CHILD_0=localhost:8081:FIX-BUG,IMPL-API:Qwen3.5-9B:mlx:8
    func registerFromEnvironment() {
        var i = 0
        while true {
            guard let spec = ProcessInfo.processInfo.environment["HAYABUSA_CHILD_\(i)"] else { break }
            let parts = spec.split(separator: ":").map(String.init)
            guard parts.count >= 4 else {
                print("[UzuDiscovery] Invalid child spec: \(spec)")
                i += 1
                continue
            }

            let host = parts[0]
            let port = Int(parts[1]) ?? 8081
            let genres = parts[2].split(separator: ",").map(String.init)
            let model = parts[3]
            let backend = parts.count > 4 ? parts[4] : "mlx"
            let slots = parts.count > 5 ? (Int(parts[5]) ?? 4) : 4

            registerManual(host: host, port: port, genres: genres, model: model, backend: backend, slots: slots)
            i += 1
        }

        if i > 0 {
            print("[UzuDiscovery] Registered \(i) child nodes from environment")
        }
    }

    /// champion_map.jsonからEloスコアを読み込んでノードに反映
    func loadEloFromChampionMap(path: String = "models/champion_map.json") {
        guard let data = FileManager.default.contents(atPath: path),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else {
            return
        }

        let nodes = orchestrator.allNodes()
        for node in nodes {
            var updatedElo = node.elo
            for (genre, info) in map {
                if let elo = info["elo"] as? Int, node.genres.contains(genre) {
                    updatedElo[genre] = elo
                }
            }
            if updatedElo != node.elo {
                var updated = node
                updated.elo = updatedElo
                orchestrator.registerNode(updated)
            }
        }
        print("[UzuDiscovery] Elo scores loaded from champion_map.json")
    }
}
