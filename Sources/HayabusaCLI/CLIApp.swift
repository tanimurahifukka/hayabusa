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
        case "health":
            await healthCheck()
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
          health     サーバーヘルスチェック

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
