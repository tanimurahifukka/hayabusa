// UzuEloManager.swift — ジャンル別Eloレーティング管理（Swift側）

import Foundation

/// Elo計算ユーティリティ
struct UzuElo {
    static let defaultElo = 1500
    static let kFactor = 32

    /// 期待勝率
    static func expectedScore(eloA: Int, eloB: Int) -> Double {
        1.0 / (1.0 + pow(10.0, Double(eloB - eloA) / 400.0))
    }

    /// Elo更新
    static func updatedElo(currentElo: Int, score: Double, opponentElo: Int) -> Int {
        let expected = expectedScore(eloA: currentElo, eloB: opponentElo)
        return currentElo + Int(Double(kFactor) * (score - expected))
    }

    /// champion_map.jsonを読み込み
    static func loadChampionMap(path: String = "models/champion_map.json") -> [String: ChampionEntry] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONDecoder().decode([String: ChampionEntry].self, from: data) else {
            return [:]
        }
        return json
    }

    /// champion_map.jsonに書き込み
    static func saveChampionMap(_ map: [String: ChampionEntry], path: String = "models/champion_map.json") {
        guard let data = try? JSONEncoder().encode(map) else { return }

        // ディレクトリ作成
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        try? data.write(to: URL(fileURLWithPath: path))
    }
}

struct ChampionEntry: Codable {
    let model: String
    let elo: Int
}
