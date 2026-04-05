// BenchCommand.swift — ジャンル別ベンチマーク実行

import Foundation

struct BenchCommand {
    static func run(args: [String]) async {
        var genre = "FIX-BUG"
        var model = "local"

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--genre":
                i += 1
                if i < args.count { genre = args[i].uppercased() }
            case "--model":
                i += 1
                if i < args.count { model = args[i] }
            default:
                break
            }
            i += 1
        }

        let client = HayabusaClient()

        do {
            try await client.ensureServerRunning()
        } catch {
            fputs("\(error)\n", stderr)
            Foundation.exit(1)
        }

        fputs("Running bench: genre=\(genre) model=\(model)\n", stderr)

        let problems = benchProblems(for: genre)
        var solved = 0
        var totalLatency: Double = 0

        for (idx, problem) in problems.enumerated() {
            let startTime = DispatchTime.now()

            do {
                let response = try await client.ask(
                    systemPrompt: problem.system,
                    userPrompt: problem.prompt,
                    maxTokens: 1024
                )

                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
                totalLatency += elapsed

                let passed = problem.check(response)
                if passed { solved += 1 }

                fputs("  [\(idx + 1)/\(problems.count)] \(passed ? "PASS" : "FAIL") (\(Int(elapsed))ms)\n", stderr)

            } catch {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
                totalLatency += elapsed
                fputs("  [\(idx + 1)/\(problems.count)] ERROR: \(error) (\(Int(elapsed))ms)\n", stderr)
            }
        }

        let score = problems.isEmpty ? 0.0 : Double(solved) / Double(problems.count)
        let avgLatency = problems.isEmpty ? 0.0 : totalLatency / Double(problems.count)

        let timestamp = ISO8601DateFormatter().string(from: Date())

        let result: [String: Any] = [
            "genre": genre,
            "model": model,
            "score": round(score * 1000) / 1000,
            "problems_solved": solved,
            "problems_total": problems.count,
            "avg_latency_ms": Int(avgLatency),
            "timestamp": timestamp,
        ]

        let jsonData = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        let jsonStr = String(data: jsonData, encoding: .utf8)!
        print(jsonStr)

        // 結果をファイルに保存
        let safeModel = model.replacingOccurrences(of: "/", with: "_")
        let safeTimestamp = timestamp.replacingOccurrences(of: ":", with: "-")
        let filename = "scripts/results/arena_\(genre)_\(safeModel)_\(safeTimestamp).json"
        try? jsonStr.write(toFile: filename, atomically: true, encoding: .utf8)
        fputs("Saved: \(filename)\n", stderr)
    }

    // MARK: - Bench Problems

    struct Problem {
        let system: String
        let prompt: String
        let check: (String) -> Bool
    }

    static func benchProblems(for genre: String) -> [Problem] {
        switch genre {
        case "FIX-BUG":
            return fixBugProblems()
        case "IMPL-ALGO":
            return implAlgoProblems()
        case "GEN-TEST":
            return genTestProblems()
        default:
            return defaultProblems(genre: genre)
        }
    }

    static func fixBugProblems() -> [Problem] {
        [
            Problem(
                system: "You are a bug fixing expert. Fix the bug and return only the corrected code.",
                prompt: """
                This Python function should return True if the list is sorted, but it has a bug:
                ```python
                def is_sorted(lst):
                    for i in range(len(lst)):
                        if lst[i] > lst[i+1]:
                            return False
                    return True
                ```
                """,
                check: { $0.contains("len(lst) - 1") || $0.contains("range(len(lst)-1)") || $0.contains("range(1, len") }
            ),
            Problem(
                system: "Fix the bug. Return only the corrected code.",
                prompt: """
                This JavaScript has an off-by-one error:
                ```javascript
                function binarySearch(arr, target) {
                  let low = 0, high = arr.length;
                  while (low < high) {
                    const mid = Math.floor((low + high) / 2);
                    if (arr[mid] === target) return mid;
                    if (arr[mid] < target) low = mid;
                    else high = mid;
                  }
                  return -1;
                }
                ```
                """,
                check: { $0.contains("low = mid + 1") || $0.contains("mid + 1") }
            ),
        ]
    }

    static func implAlgoProblems() -> [Problem] {
        [
            Problem(
                system: "Write only the function. No explanation.",
                prompt: "Write a Python function `def fibonacci(n: int) -> int` that returns the nth Fibonacci number (0-indexed).",
                check: { $0.contains("def fibonacci") && ($0.contains("return") || $0.contains("yield")) }
            ),
            Problem(
                system: "Write only the function. No explanation.",
                prompt: "Write a Python function `def is_palindrome(s: str) -> bool` that checks if a string is a palindrome ignoring case and non-alphanumeric characters.",
                check: { $0.contains("def is_palindrome") && $0.contains("return") }
            ),
        ]
    }

    static func genTestProblems() -> [Problem] {
        [
            Problem(
                system: "Generate pytest test cases for the given function.",
                prompt: """
                ```python
                def add(a: int, b: int) -> int:
                    return a + b
                ```
                """,
                check: { $0.contains("def test_") && $0.contains("assert") }
            ),
        ]
    }

    static func defaultProblems(genre: String) -> [Problem] {
        [
            Problem(
                system: "Answer the question concisely.",
                prompt: "What is the purpose of the \(genre) task category in software development? Answer in one sentence.",
                check: { !$0.isEmpty && $0.count > 10 }
            ),
        ]
    }
}
