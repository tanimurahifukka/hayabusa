// SavingsTracker.swift — KAJIBA節約率トラッカー
// 各コマンド実行時にトークン節約量を自動記録

import Foundation

struct SavingsTracker {
    static let logPath = NSHomeDirectory() + "/.hayabusa/savings.jsonl"

    /// 節約イベントをログに記録
    static func log(type: String, tokensSaved: Int, latencyMs: Int = 0, extra: [String: Any] = [:]) {
        let dir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Claude Output cost: $75/MTok = $0.075/1Ktok
        let costSaved = Double(tokensSaved) / 1000.0 * 0.075

        var entry: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "type": type,
            "tokens_saved": tokensSaved,
            "latency_ms": latencyMs,
            "cost_saved_usd": round(costSaved * 1_000_000) / 1_000_000,
        ]
        for (k, v) in extra {
            entry[k] = v
        }

        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }

        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? (line + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// classify実行時の節約: 分類結果をClaudeに投げずにローカルで判定
    static func logClassify(latencyMs: Int, category: String, confidence: Double) {
        // classify自体のトークン節約: プロンプト~100tok + 出力~50tok = ~150tok
        log(type: "classify", tokensSaved: 150, latencyMs: latencyMs,
            extra: ["category": category, "confidence": confidence])
    }

    /// compress実行時の節約: 圧縮分のトークンが節約
    static func logCompress(originalTokens: Int, compressedTokens: Int, latencyMs: Int = 0) {
        let saved = originalTokens - compressedTokens
        log(type: "compress", tokensSaved: saved, latencyMs: latencyMs,
            extra: ["original_tokens": originalTokens, "compressed_tokens": compressedTokens])
    }

    /// ask実行時の節約: 全トークンがローカル処理
    static func logAsk(estimatedTokens: Int, latencyMs: Int = 0) {
        log(type: "ask", tokensSaved: estimatedTokens, latencyMs: latencyMs)
    }

    /// judge実行時の節約
    static func logJudge(latencyMs: Int = 0) {
        // judge: プロンプト~500tok + 出力~200tok = ~700tok
        log(type: "judge", tokensSaved: 700, latencyMs: latencyMs)
    }
}
