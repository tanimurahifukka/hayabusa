// JudgeCommand.swift — 2つの回答を品質比較するArena用コマンド

import Foundation

struct JudgeCommand {
    static let systemPrompt = """
    あなたはコード品質の審判です。2つの回答を比較して、どちらが優れているか判定してください。

    評価基準:
    1. 正確性（バグがないか、要件を満たしているか）
    2. コード品質（可読性、保守性、エラーハンドリング）
    3. 効率性（パフォーマンス、メモリ使用量）
    4. 完全性（エッジケース対応、テスト考慮）

    必ず以下のJSON形式で回答してください（他の文章は出力しない）:
    {"winner": "a" or "b", "scores": {"a": 0.0-1.0, "b": 0.0-1.0}, "reason": "理由（1文）"}
    """

    static func run(args: [String]) async {
        // 引数パース: --a "..." --b "..." --task "..."
        var responseA = ""
        var responseB = ""
        var task = ""

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--a":
                i += 1
                if i < args.count { responseA = args[i] }
            case "--b":
                i += 1
                if i < args.count { responseB = args[i] }
            case "--task":
                i += 1
                if i < args.count { task = args[i] }
            default:
                break
            }
            i += 1
        }

        guard !responseA.isEmpty, !responseB.isEmpty else {
            fputs("Usage: hayabusa judge --a \"<response_a>\" --b \"<response_b>\" --task \"<task>\"\n", stderr)
            Foundation.exit(1)
        }

        let client = HayabusaClient()

        do {
            try await client.ensureServerRunning()
        } catch {
            fputs("\(error)\n", stderr)
            Foundation.exit(1)
        }

        let userPrompt = """
        タスク: \(task.isEmpty ? "コード品質比較" : task)

        === 回答A ===
        \(responseA)

        === 回答B ===
        \(responseB)
        """

        do {
            let rawResponse = try await client.ask(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: 256
            )

            // JSONパース
            let parsed = parseJudgeResponse(rawResponse, task: task)
            let jsonData = try JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys])
            print(String(data: jsonData, encoding: .utf8)!)

        } catch {
            fputs("Error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func parseJudgeResponse(_ raw: String, task: String) -> [String: Any] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // まず全体をJSONとしてパース（ネストされたオブジェクトに対応）
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var result = json
            if result["genre"] == nil {
                result["genre"] = task.isEmpty ? "UNKNOWN" : task
            }
            return result
        }

        // 最初の{から最後の}までを抽出してパース
        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            let jsonStr = String(trimmed[start...end])
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var result = json
                if result["genre"] == nil {
                    result["genre"] = task.isEmpty ? "UNKNOWN" : task
                }
                return result
            }
        }

        // パース失敗
        return [
            "winner": "unknown",
            "scores": ["a": 0.5, "b": 0.5],
            "reason": "判定結果のパースに失敗しました",
            "genre": task.isEmpty ? "UNKNOWN" : task,
            "raw_response": trimmed,
        ]
    }
}
