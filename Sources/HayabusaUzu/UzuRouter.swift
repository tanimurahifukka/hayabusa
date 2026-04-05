// UzuRouter.swift — ジャンル別ルーティング + フェイルオーバー
// 1. Classify-0.6Bでジャンル判定
// 2. confidence > 0.85 → Eloチャンピオン
// 3. confidence 0.6〜0.85 → 汎用Qwen3.5で再判定
// 4. confidence < 0.6 / O-CLINICAL → エスカレーション

import Foundation

/// ルーティング結果
enum RouteResult: Sendable {
    case specialist(UzuNode)       // 専門ノードへ転送
    case reclassify(UzuNode)       // 汎用ノードで再判定
    case escalate                  // Claude Codeへエスカレーション
}

/// ルーティング判定結果の詳細
struct RouteDecision: Codable, Sendable {
    let genre: String
    let confidence: Double
    let action: String          // "ROUTE_SPECIALIST" / "RECLASSIFY" / "ESCALATE"
    let targetNodeId: String?
    let latencyMs: Int
}

final class UzuRouter: @unchecked Sendable {
    let orchestrator: UzuOrchestrator

    init(orchestrator: UzuOrchestrator) {
        self.orchestrator = orchestrator
    }

    /// メッセージ内容からルーティング先を決定
    func route(userMessage: String) async throws -> (RouteResult, RouteDecision) {
        let startTime = DispatchTime.now()

        // Step 1: Classifyノードでジャンル判定
        let (genre, confidence) = try await classify(userMessage)

        let elapsed = Int(Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

        // Step 2: O-CLINICALは常にエスカレーション
        if genre == "O-CLINICAL" {
            let decision = RouteDecision(genre: genre, confidence: confidence, action: "ESCALATE_CLINICAL", targetNodeId: nil, latencyMs: elapsed)
            return (.escalate, decision)
        }

        // Step 3: confidenceに応じたルーティング
        if confidence > 0.85 {
            if let node = orchestrator.route(genre: genre, confidence: confidence) {
                let decision = RouteDecision(genre: genre, confidence: confidence, action: "ROUTE_SPECIALIST", targetNodeId: node.id, latencyMs: elapsed)
                return (.specialist(node), decision)
            }
            // 専門ノードなし → エスカレーション
            let decision = RouteDecision(genre: genre, confidence: confidence, action: "ESCALATE_NO_SPECIALIST", targetNodeId: nil, latencyMs: elapsed)
            return (.escalate, decision)

        } else if confidence >= 0.6 {
            if let generalNode = orchestrator.findGeneralNode() {
                let decision = RouteDecision(genre: genre, confidence: confidence, action: "RECLASSIFY", targetNodeId: generalNode.id, latencyMs: elapsed)
                return (.reclassify(generalNode), decision)
            }
            // 汎用ノードなし → エスカレーション
            let decision = RouteDecision(genre: genre, confidence: confidence, action: "ESCALATE_NO_GENERAL", targetNodeId: nil, latencyMs: elapsed)
            return (.escalate, decision)

        } else {
            let decision = RouteDecision(genre: genre, confidence: confidence, action: "ESCALATE_LOW_CONFIDENCE", targetNodeId: nil, latencyMs: elapsed)
            return (.escalate, decision)
        }
    }

    // MARK: - Classify

    /// Classify専用ノードにリクエストを投げてジャンル判定
    private func classify(_ text: String) async throws -> (String, Double) {
        let classifyURL = URL(string: "http://127.0.0.1:\(orchestrator.classifyPort)/v1/chat/completions")!

        let systemPrompt = """
        あなたはタスク分類の専門家です。カテゴリと確信度をJSON形式で返してください。
        カテゴリ: IMPL-ALGO, IMPL-API, IMPL-UI, IMPL-DB, IMPL-PAYMENT, FIX-BUG, FIX-REFACTOR, FIX-PERF, GEN-TEST, GEN-DOCS, O-CLINICAL, CLASSIFY, COMPRESS
        フォーマット: {"category": "FIX-BUG", "confidence": 0.92}
        """

        let payload: [String: Any] = [
            "model": "local",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text],
            ],
            "max_tokens": 64,
            "temperature": 0,
        ]

        var request = URLRequest(url: classifyURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""

            // JSONパース
            if let jsonRange = content.range(of: "\\{[^}]+\\}", options: .regularExpression),
               let jsonData = String(content[jsonRange]).data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let category = parsed["category"] as? String {
                let confidence = (parsed["confidence"] as? Double) ?? 0.5
                return (category, confidence)
            }

            return ("CLASSIFY", 0.3)
        } catch {
            // Classifyノード不通 → 低confidenceでエスカレーション
            return ("CLASSIFY", 0.1)
        }
    }
}
