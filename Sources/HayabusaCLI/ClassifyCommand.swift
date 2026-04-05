// ClassifyCommand.swift — タスク分類コマンド
// confidence 3段階フォールバック: >0.85直行、0.6-0.85再判定、<0.6エスカレーション
// O-CLINICALは常にエスカレーション

import Foundation

struct ClassifyCommand {
    // ジャンル定義
    static let genres = [
        "IMPL-ALGO", "IMPL-API", "IMPL-UI", "IMPL-DB", "IMPL-PAYMENT",
        "FIX-BUG", "FIX-REFACTOR", "FIX-PERF",
        "GEN-TEST", "GEN-DOCS",
        "O-CLINICAL",
        "CLASSIFY", "COMPRESS",
    ]

    static let systemPrompt = """
    あなたはタスク分類の専門家です。与えられたタスク説明を以下のカテゴリの1つに分類してください。

    カテゴリ一覧:
    - IMPL-ALGO: アルゴリズム・データ構造の実装
    - IMPL-API: API実装・エンドポイント
    - IMPL-UI: フロント・コンポーネント
    - IMPL-DB: DB設計・クエリ
    - IMPL-PAYMENT: 決済実装
    - FIX-BUG: バグ修正・デバッグ
    - FIX-REFACTOR: リファクタリング
    - FIX-PERF: パフォーマンス改善
    - GEN-TEST: テストコード生成
    - GEN-DOCS: ドキュメント生成
    - O-CLINICAL: クリニック業務（医療・レセプト・ORCA・SOAP・カルテ）
    - CLASSIFY: 分類・判定タスク
    - COMPRESS: 圧縮・要約タスク

    必ず以下のJSON形式で回答してください（他の文章は出力しない）:
    {"category": "カテゴリ名", "confidence": 0.0〜1.0の数値}
    """

    static func run(args: [String]) async {
        guard !args.isEmpty else {
            fputs("Usage: hayabusa classify \"<text>\" [--categories cat1,cat2,...]\n", stderr)
            Foundation.exit(1)
        }

        let text = args.first!
        let client = HayabusaClient()

        do {
            try await client.ensureServerRunning()
        } catch {
            fputs("\(error)\n", stderr)
            Foundation.exit(1)
        }

        let startTime = DispatchTime.now()

        do {
            let rawResponse = try await client.ask(
                systemPrompt: systemPrompt,
                userPrompt: text,
                maxTokens: 64
            )

            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000

            // JSONをパース（LLM出力からJSON部分を抽出）
            let parsed = parseClassifyResponse(rawResponse)

            let result: [String: Any] = [
                "category": parsed.category,
                "confidence": parsed.confidence,
                "latency_ms": Int(elapsed),
                "action": routingAction(category: parsed.category, confidence: parsed.confidence),
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(data: jsonData, encoding: .utf8)!)

            // 節約ログ記録
            SavingsTracker.logClassify(latencyMs: Int(elapsed), category: parsed.category, confidence: parsed.confidence)

        } catch {
            fputs("Error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    // MARK: - Routing

    static func routingAction(category: String, confidence: Double) -> String {
        // O-CLINICALは常にエスカレーション
        if category == "O-CLINICAL" {
            return "ESCALATE_CLAUDE"
        }
        if confidence > 0.85 {
            return "ROUTE_SPECIALIST"
        } else if confidence >= 0.6 {
            return "RECLASSIFY_QWEN"
        } else {
            return "ESCALATE_CLAUDE"
        }
    }

    // MARK: - Parse

    struct ClassifyResult {
        let category: String
        let confidence: Double
    }

    static func parseClassifyResponse(_ raw: String) -> ClassifyResult {
        // LLM出力からJSON部分を抽出
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // JSONを直接パース試行
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let category = json["category"] as? String {
            let confidence = (json["confidence"] as? Double) ?? 0.5
            return ClassifyResult(category: category, confidence: confidence)
        }

        // ```json ... ``` ブロックから抽出
        if let range = trimmed.range(of: "\\{[^}]+\\}", options: .regularExpression) {
            let jsonStr = String(trimmed[range])
            if let data = jsonStr.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let category = json["category"] as? String {
                let confidence = (json["confidence"] as? Double) ?? 0.5
                return ClassifyResult(category: category, confidence: confidence)
            }
        }

        // パース失敗 → 低confidence
        return ClassifyResult(category: "CLASSIFY", confidence: 0.3)
    }
}
