// AgentCommand.swift — ローカルマルチエージェントパイプライン
// Planner → Coder → Reviewer(Codex) → Tester
// 3/4がローカル$0、Reviewerだけ外部API

import Foundation

struct AgentCommand {

    // エージェント定義
    enum Agent: String, CaseIterable {
        case planner  = "PLANNER"
        case coder    = "CODER"
        case reviewer = "REVIEWER"
        case tester   = "TESTER"

        var emoji: String {
            switch self {
            case .planner:  return "📋"
            case .coder:    return "💻"
            case .reviewer: return "🔍"
            case .tester:   return "🧪"
            }
        }

        var backend: String {
            switch self {
            case .reviewer: return "codex"
            default:        return "local"
            }
        }
    }

    // パイプラインの各ステップ結果
    struct StepResult {
        let agent: Agent
        let output: String
        let latencyMs: Int
        let tokens: Int
        let cost: Double  // $0 for local, >0 for Codex
    }

    static func run(args: [String]) async {
        // 引数パース
        var task = ""
        var codexEndpoint = "https://api.openai.com/v1/chat/completions"
        var codexModel = "o3-mini"
        var codexKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
        var skipReview = false
        var hayabusaPort = 8080

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--codex-endpoint":
                i += 1; if i < args.count { codexEndpoint = args[i] }
            case "--codex-model":
                i += 1; if i < args.count { codexModel = args[i] }
            case "--codex-key":
                i += 1; if i < args.count { codexKey = args[i] }
            case "--skip-review":
                skipReview = true
            case "--port":
                i += 1; if i < args.count { hayabusaPort = Int(args[i]) ?? 8080 }
            default:
                if !args[i].hasPrefix("-") && task.isEmpty {
                    task = args[i]
                }
            }
            i += 1
        }

        guard !task.isEmpty else {
            printUsage()
            return
        }

        let client = HayabusaClient(port: hayabusaPort)
        do {
            try await client.ensureServerRunning()
        } catch {
            fputs("\(error)\n", stderr)
            Foundation.exit(1)
        }

        fputs("\n", stderr)
        fputs("╔══════════════════════════════════════════════════════╗\n", stderr)
        fputs("║  KAJIBA Multi-Agent Pipeline                        ║\n", stderr)
        fputs("╠══════════════════════════════════════════════════════╣\n", stderr)
        fputs("║  📋 Planner (local) → 💻 Coder (local)              ║\n", stderr)
        fputs("║  → 🔍 Reviewer (Codex) → 🧪 Tester (local)         ║\n", stderr)
        fputs("╚══════════════════════════════════════════════════════╝\n", stderr)
        fputs("Task: \(task)\n\n", stderr)

        var results: [StepResult] = []
        var totalCost = 0.0

        // ── Step 1: Planner ──
        fputs("📋 PLANNER: 実装計画を立案中...\n", stderr)
        let planResult = await runLocal(client: client, agent: .planner, systemPrompt: """
        あなたは実装プランナーです。与えられたタスクを分析し、実装計画を立ててください。

        以下の形式で出力:
        ## 要件
        - 要件1
        - 要件2

        ## 実装ステップ
        1. ステップ1
        2. ステップ2

        ## 使用技術
        - 技術1

        ## エッジケース
        - ケース1
        """, userPrompt: task)
        results.append(planResult)
        fputs("  ✓ 計画完了 (\(planResult.latencyMs)ms, \(planResult.tokens)tok, $\(String(format: "%.4f", planResult.cost)))\n\n", stderr)

        // ── Step 2: Coder ──
        fputs("💻 CODER: コードを実装中...\n", stderr)
        let coderResult = await runLocal(client: client, agent: .coder, systemPrompt: """
        あなたは優秀なプログラマーです。プランナーの計画に基づいてコードを実装してください。
        コードのみを出力してください。コメントは最小限に。
        """, userPrompt: """
        ## タスク
        \(task)

        ## プランナーの計画
        \(planResult.output)
        """)
        results.append(coderResult)
        fputs("  ✓ 実装完了 (\(coderResult.latencyMs)ms, \(coderResult.tokens)tok, $\(String(format: "%.4f", coderResult.cost)))\n\n", stderr)

        // ── Step 3: Reviewer (Codex) ──
        if skipReview || codexKey.isEmpty {
            fputs("🔍 REVIEWER: ", stderr)
            if codexKey.isEmpty {
                fputs("Skipped (OPENAI_API_KEY not set. Set it or use --codex-key)\n\n", stderr)
            } else {
                fputs("Skipped (--skip-review)\n\n", stderr)
            }
            // ローカルでフォールバックレビュー
            fputs("🔍 REVIEWER (fallback to local): レビュー中...\n", stderr)
            let reviewResult = await runLocal(client: client, agent: .reviewer, systemPrompt: """
            あなたはシニアコードレビュワーです。以下のコードをレビューしてください。

            チェック項目:
            1. バグ・エラーハンドリング
            2. セキュリティ（インジェクション、XSS等）
            3. パフォーマンス
            4. 可読性・命名
            5. エッジケース

            以下の形式で出力:
            ## 評価: PASS / NEEDS_FIX
            ## 問題点
            - 問題1: 説明
            ## 修正提案
            - 提案1
            """, userPrompt: coderResult.output)
            results.append(reviewResult)
            fputs("  ✓ レビュー完了 (\(reviewResult.latencyMs)ms, $\(String(format: "%.4f", reviewResult.cost)))\n\n", stderr)
        } else {
            fputs("🔍 REVIEWER (Codex \(codexModel)): レビュー中...\n", stderr)
            let reviewResult = await runCodex(
                endpoint: codexEndpoint,
                model: codexModel,
                apiKey: codexKey,
                code: coderResult.output,
                task: task
            )
            results.append(reviewResult)
            totalCost += reviewResult.cost
            fputs("  ✓ レビュー完了 (\(reviewResult.latencyMs)ms, \(reviewResult.tokens)tok, $\(String(format: "%.4f", reviewResult.cost)))\n\n", stderr)
        }

        let reviewOutput = results.last!.output

        // ── Step 4: Tester ──
        fputs("🧪 TESTER: テストコード生成中...\n", stderr)
        let testerResult = await runLocal(client: client, agent: .tester, systemPrompt: """
        あなたはテストエンジニアです。以下のコードに対するテストコードを生成してください。
        pytestまたはjestの形式で、エッジケースも含めて網羅的にテストしてください。
        テストコードのみを出力してください。
        """, userPrompt: """
        ## 実装コード
        \(coderResult.output)

        ## レビュー結果
        \(reviewOutput)
        """)
        results.append(testerResult)
        fputs("  ✓ テスト生成完了 (\(testerResult.latencyMs)ms, \(testerResult.tokens)tok, $\(String(format: "%.4f", testerResult.cost)))\n\n", stderr)

        // ── 結果出力 ──
        let totalLatency = results.reduce(0) { $0 + $1.latencyMs }
        let totalTokens = results.reduce(0) { $0 + $1.tokens }
        totalCost = results.reduce(0.0) { $0 + $1.cost }
        let localSteps = results.filter { $0.agent.backend == "local" }.count
        let codexSteps = results.filter { $0.agent.backend == "codex" }.count

        fputs("══════════════════════════════════════════════════════\n", stderr)
        fputs("  Pipeline Complete\n", stderr)
        fputs("══════════════════════════════════════════════════════\n", stderr)
        fputs("  Total: \(totalLatency)ms | \(totalTokens) tokens | $\(String(format: "%.4f", totalCost))\n", stderr)
        fputs("  Local steps: \(localSteps) ($0) | Codex steps: \(codexSteps)\n", stderr)
        fputs("══════════════════════════════════════════════════════\n\n", stderr)

        // JSON出力
        let output: [String: Any] = [
            "task": task,
            "pipeline": results.map { r -> [String: Any] in
                ["agent": r.agent.rawValue, "backend": r.agent.backend,
                 "latency_ms": r.latencyMs, "tokens": r.tokens, "cost": r.cost,
                 "output": r.output]
            },
            "summary": [
                "total_latency_ms": totalLatency,
                "total_tokens": totalTokens,
                "total_cost": totalCost,
                "local_steps": localSteps,
                "codex_steps": codexSteps,
            ],
        ]
        let jsonData = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(data: jsonData, encoding: .utf8)!)

        // 節約ログ
        SavingsTracker.log(type: "agent_pipeline", tokensSaved: totalTokens, latencyMs: totalLatency,
                          extra: ["local_steps": localSteps, "codex_steps": codexSteps])
    }

    // ── Local Agent（Hayabusa） ──
    static func runLocal(client: HayabusaClient, agent: Agent, systemPrompt: String, userPrompt: String) async -> StepResult {
        let start = DispatchTime.now()
        do {
            let response = try await client.chatCompletion(
                messages: [
                    ["role": "system", "content": systemPrompt],
                    ["role": "user", "content": userPrompt],
                ],
                maxTokens: 1024,
                temperature: 0.0
            )
            let elapsed = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            let content = response.choices.first?.message.content ?? ""
            let tokens = (response.usage?.completion_tokens ?? 0) + (response.usage?.prompt_tokens ?? 0)
            return StepResult(agent: agent, output: content, latencyMs: elapsed, tokens: tokens, cost: 0.0)
        } catch {
            let elapsed = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            return StepResult(agent: agent, output: "ERROR: \(error)", latencyMs: elapsed, tokens: 0, cost: 0.0)
        }
    }

    // ── Codex Agent（外部API） ──
    static func runCodex(endpoint: String, model: String, apiKey: String, code: String, task: String) async -> StepResult {
        let start = DispatchTime.now()

        let systemPrompt = """
        You are a senior code reviewer. Review the following code for:
        1. Bugs and error handling
        2. Security issues (injection, XSS, etc.)
        3. Performance
        4. Readability
        5. Edge cases

        Output format:
        ## Verdict: PASS / NEEDS_FIX
        ## Issues
        - Issue 1: description
        ## Suggestions
        - Suggestion 1
        """

        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": "Task: \(task)\n\nCode:\n\(code)"],
            ],
            "max_tokens": 512,
            "temperature": 0,
        ]

        guard let url = URL(string: endpoint),
              let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return StepResult(agent: .reviewer, output: "ERROR: Invalid endpoint", latencyMs: 0, tokens: 0, cost: 0.0)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 60

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let elapsed = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

            let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            let usage = json?["usage"] as? [String: Any]
            let inputTokens = usage?["prompt_tokens"] as? Int ?? 0
            let outputTokens = usage?["completion_tokens"] as? Int ?? 0
            // OpenAI pricing varies by model, rough estimate
            let cost = Double(inputTokens) * 0.001 / 1000 + Double(outputTokens) * 0.002 / 1000

            return StepResult(agent: .reviewer, output: content, latencyMs: elapsed, tokens: inputTokens + outputTokens, cost: cost)
        } catch {
            let elapsed = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            return StepResult(agent: .reviewer, output: "ERROR: \(error)", latencyMs: elapsed, tokens: 0, cost: 0.0)
        }
    }

    static func printUsage() {
        fputs("""
        Usage: hayabusa agent "<task>" [options]

        Multi-agent pipeline: Planner → Coder → Reviewer(Codex) → Tester

        Options:
          --codex-endpoint URL   Codex API endpoint (default: OpenAI)
          --codex-model MODEL    Codex model (default: o3-mini)
          --codex-key KEY        API key (or set OPENAI_API_KEY)
          --skip-review          Skip Codex review (local fallback)
          --port PORT            Hayabusa port (default: 8080)

        Examples:
          hayabusa agent "Pythonでバイナリサーチを実装"
          hayabusa agent "React Todoアプリ" --codex-model gpt-4o
          hayabusa agent "SQLインジェクション修正" --skip-review


        """, stderr)
    }
}
