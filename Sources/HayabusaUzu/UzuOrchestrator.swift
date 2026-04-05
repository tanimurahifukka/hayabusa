// UzuOrchestrator.swift — 親ノードのルーティング本体
// ジャンル別classify → Eloチャンピオン → フェイルオーバー

import Foundation

/// Uzuクラスターモード: parent / child / solo
enum UzuMode: String {
    case parent  // ルーター + classify + ジャンル別ルーティング
    case child   // 特定ジャンル専門ノード
    case solo    // 従来モード（デフォルト・後方互換）
}

/// Uzuクラスター内のノード情報
struct UzuNode: Codable, Sendable {
    let id: String
    let host: String
    let port: Int
    let genres: [String]     // 担当ジャンル
    let model: String
    let backend: String
    let slots: Int
    var isHealthy: Bool
    var lastSeen: Date
    var elo: [String: Int]   // ジャンル別Eloスコア

    var baseURL: String { "http://\(host):\(port)" }
}

/// 親ノードのオーケストレーター
final class UzuOrchestrator: @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [String: UzuNode] = [:]
    private var championMap: [String: String] = [:]  // genre → nodeId

    let classifyPort: Int   // classify専用ノードのポート
    let parentPort: Int

    init(parentPort: Int = 8080, classifyPort: Int = 8098) {
        self.parentPort = parentPort
        self.classifyPort = classifyPort
    }

    // MARK: - ノード管理

    func registerNode(_ node: UzuNode) {
        lock.withLock {
            nodes[node.id] = node
            updateChampionMap()
        }
        print("[Uzu] Node registered: \(node.id) genres=\(node.genres) model=\(node.model)")
    }

    func unregisterNode(id: String) {
        lock.withLock {
            nodes.removeValue(forKey: id)
            updateChampionMap()
        }
        print("[Uzu] Node unregistered: \(id)")
    }

    func allNodes() -> [UzuNode] {
        lock.withLock { Array(nodes.values) }
    }

    func getChampionMap() -> [String: String] {
        lock.withLock { championMap }
    }

    // MARK: - ルーティング

    /// ジャンル判定 → 最適ノード選択
    func route(genre: String, confidence: Double) -> UzuNode? {
        lock.withLock {
            // O-CLINICALは常にエスカレーション（nilを返す = Claude Code行き）
            if genre == "O-CLINICAL" {
                return nil
            }

            // confidence低い場合もエスカレーション
            if confidence < 0.6 {
                return nil
            }

            // チャンピオンノードを探す
            if let champId = championMap[genre], let node = nodes[champId], node.isHealthy {
                return node
            }

            // フェイルオーバー: 同ジャンル対応の健全なノードからElo最高を選択
            let candidates = nodes.values
                .filter { $0.isHealthy && $0.genres.contains(genre) }
                .sorted { ($0.elo[genre] ?? 0) > ($1.elo[genre] ?? 0) }

            return candidates.first
        }
    }

    /// 汎用Qwen3.5ノードを探す（confidence 0.6-0.85の再判定用）
    func findGeneralNode() -> UzuNode? {
        lock.withLock {
            nodes.values
                .filter { $0.isHealthy && $0.model.contains("Qwen3.5") }
                .first
        }
    }

    // MARK: - チャンピオンマップ更新

    private func updateChampionMap() {
        // 各ジャンルでElo最高の健全ノードをチャンピオンに
        var allGenres = Set<String>()
        for node in nodes.values {
            allGenres.formUnion(node.genres)
        }

        for genre in allGenres {
            let best = nodes.values
                .filter { $0.isHealthy && $0.genres.contains(genre) }
                .max { ($0.elo[genre] ?? 0) < ($1.elo[genre] ?? 0) }
            championMap[genre] = best?.id
        }
    }

    // MARK: - HTTP転送

    func forward(to node: UzuNode, requestBody: Data) async throws -> Data {
        let url = URL(string: "\(node.baseURL)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UzuError.forwardFailed(node.id)
        }
        return data
    }
}

// MARK: - JSON出力

extension UzuOrchestrator {
    func nodesJSON() -> String {
        let nodes = allNodes().map { node -> [String: Any] in
            [
                "id": node.id,
                "host": node.host,
                "port": node.port,
                "genres": node.genres,
                "model": node.model,
                "isHealthy": node.isHealthy,
                "elo": node.elo,
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: nodes, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    func championMapJSON() -> String {
        let map = getChampionMap()
        let data = try! JSONSerialization.data(withJSONObject: map, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}

enum UzuError: Error {
    case forwardFailed(String)
    case noNodeAvailable(String)
    case classifyFailed
}
