// CompressCommand.swift — Saku圧縮コマンド
// 目標削減率: 17.5%（Saku論文実測値）

import Foundation

struct CompressCommand {
    static let systemPrompt = """
    あなたはプロンプト圧縮の専門家です。与えられたテキストの意味を完全に保持しながら、できるだけ短く圧縮してください。

    ルール:
    - 意味を変えない
    - 重要な技術用語、数値、固有名詞は保持する
    - 冗長な表現、繰り返し、フィラーワードを削除する
    - コードブロックは圧縮しない（そのまま保持）
    - 圧縮後のテキストのみを出力する（説明文は不要）
    """

    static func run(args: [String]) async {
        guard !args.isEmpty else {
            fputs("Usage: hayabusa compress \"<text>\" [--ratio 0.8]\n", stderr)
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

        do {
            let compressed = try await client.ask(
                systemPrompt: systemPrompt,
                userPrompt: text,
                maxTokens: max(64, text.count)  // 圧縮後は短くなるはず
            )

            // トークン数の概算（英語: ~4文字/トークン、日本語: ~1.5文字/トークン）
            let originalTokens = estimateTokens(text)
            let compressedTokens = estimateTokens(compressed)
            let reductionRate = originalTokens > 0
                ? Double(originalTokens - compressedTokens) / Double(originalTokens)
                : 0.0

            let result: [String: Any] = [
                "compressed": compressed,
                "original_tokens": originalTokens,
                "compressed_tokens": compressedTokens,
                "reduction_rate": round(reductionRate * 1000) / 1000,
            ]

            let jsonData = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(data: jsonData, encoding: .utf8)!)

        } catch {
            fputs("Error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    // トークン数概算（正確にはtokenizerが必要だが、CLIは軽量に保つ）
    static func estimateTokens(_ text: String) -> Int {
        // 簡易推定: 日本語は1.5文字/トークン、英語は4文字/トークン
        var jpCount = 0
        var enCount = 0
        for char in text.unicodeScalars {
            if char.value > 0x3000 {
                jpCount += 1
            } else {
                enCount += 1
            }
        }
        return Int(Double(jpCount) / 1.5) + Int(Double(enCount) / 4.0)
    }
}
