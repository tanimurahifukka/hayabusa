// main.swift — KAJIBA CLI エントリポイント
// 軽量HTTPクライアント。モデルロードしない。起動オーバーヘッドはcurlと同程度。

import Foundation

@main
struct HayabusaCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        guard let command = args.first else {
            printUsage()
            return
        }

        let subArgs = Array(args.dropFirst())

        switch command {
        case "server":
            await ServerCommand.run(args: subArgs)
        case "classify":
            await ClassifyCommand.run(args: subArgs)
        case "compress":
            await CompressCommand.run(args: subArgs)
        case "judge":
            await JudgeCommand.run(args: subArgs)
        case "bench":
            await BenchCommand.run(args: subArgs)
        case "agent":
            await AgentCommand.run(args: subArgs)
        case "health":
            await healthCheck()
        case "savings":
            showSavings()
        case "--help", "-h", "help":
            printUsage()
        case "--version", "-v":
            print("hayabusa-cli 1.0.0 (KAJIBA)")
        default:
            fputs("Unknown command: \(command)\n", stderr)
            printUsage()
            Foundation.exit(1)
        }
    }

    static func healthCheck() async {
        let client = HayabusaClient()
        do {
            let ok = try await client.health()
            print(ok ? "{\"status\":\"ok\"}" : "{\"status\":\"error\"}")
        } catch {
            print("{\"status\":\"error\",\"message\":\"\(error)\"}")
            Foundation.exit(1)
        }
    }

    static func showSavings() {
        let logPath = NSHomeDirectory() + "/.hayabusa/savings.jsonl"
        guard let content = try? String(contentsOfFile: logPath, encoding: .utf8) else {
            print("No savings data yet. Use classify/compress/judge to start tracking.")
            return
        }

        var totalTokens = 0
        var totalCost = 0.0
        var count = 0
        var byType: [String: (count: Int, tokens: Int, cost: Double)] = [:]

        for line in content.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            let type = entry["type"] as? String ?? "unknown"
            let tokens = (entry["tokens_saved"] as? Int) ?? Int(entry["tokens_saved"] as? Double ?? 0)
            let cost = (entry["cost_saved_usd"] as? Double) ?? 0

            totalTokens += tokens
            totalCost += cost
            count += 1

            let prev = byType[type] ?? (0, 0, 0)
            byType[type] = (prev.count + 1, prev.tokens + tokens, prev.cost + cost)
        }

        print("")
        print("KAJIBA Savings Report")
        print("=====================")
        for (type, data) in byType.sorted(by: { $0.value.tokens > $1.value.tokens }) {
            print("  \(type): \(data.count) calls, \(data.tokens) tokens saved, $\(String(format: "%.4f", data.cost))")
        }
        print("-----")
        print("  TOTAL: \(count) calls, \(totalTokens) tokens saved, $\(String(format: "%.4f", totalCost))")
        print("")
    }

    static func printUsage() {
        print("""
        KAJIBA - Hayabusa Specialist AI Forge

        Usage: hayabusa <command> [options]

        Commands:
          server     サーバーデーモン管理 (start/stop/status/install)
          classify   タスク分類（ローカルLLM・$0）
          compress   プロンプト圧縮（Saku圧縮・17.5%削減）
          judge      2回答の品質比較（Arena用）
          bench      ジャンル別ベンチマーク実行
          agent      マルチエージェント (Planner→Coder→Reviewer→Tester)
          health     サーバーヘルスチェック
          savings    トークン節約レポート表示

        Examples:
          hayabusa server start models/Qwen3.5-9B-Q4_K_M.gguf
          hayabusa classify "Stripeのwebhook署名検証でエラーが出る"
          hayabusa compress "長いプロンプトテキスト..."
          hayabusa judge --a "回答A" --b "回答B" --task "FIX-BUG"
          hayabusa bench --genre FIX-BUG --model local

        Fire up your AI. $0/inference.
        """)
    }
}
