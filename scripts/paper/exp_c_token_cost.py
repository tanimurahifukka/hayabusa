#!/usr/bin/env python3
"""Experiment C: Token Cost Reduction — Claude-only vs KAJIBA統合.

Claude単独利用時とKAJIBA統合時のトークンコストを比較する。
タスクをlight/medium/heavyに分類し、KAJIBAルーティングによる
トークン削減率とコスト削減を計測する。

Usage:
    python scripts/paper/exp_c_token_cost.py
    python scripts/paper/exp_c_token_cost.py --hayabusa-url http://localhost:8080
    python scripts/paper/exp_c_token_cost.py --tasks my_tasks.jsonl
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import statistics
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import aiohttp

# ── 再現性 ───────────────────────────────────────────────────────────
random.seed(42)

SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "results"

# Claude Opus 4.6 コスト（per 1M tokens）
CLAUDE_INPUT_COST_PER_MTOK = 15.0    # $15/MTok
CLAUDE_OUTPUT_COST_PER_MTOK = 75.0   # $75/MTok


# ── タスク生成 ────────────────────────────────────────────────────────

def generate_tasks() -> list[dict]:
    """100タスクを生成: 30 light, 50 medium, 20 heavy."""
    tasks = []

    # Light tasks（30件）: 簡単な質問、分類、フォーマット変換
    # Hayabusaローカルで完結可能
    light_templates = [
        {"prompt": "次の文章を日本語に翻訳してください: 'The quick brown fox jumps over the lazy dog.'",
         "category": "translation", "estimated_input_tokens": 30, "estimated_output_tokens": 20},
        {"prompt": "以下のJSONをYAMLに変換: {\"name\": \"test\", \"value\": 42}",
         "category": "format_conversion", "estimated_input_tokens": 25, "estimated_output_tokens": 15},
        {"prompt": "「機械学習」を英語で何と言いますか？",
         "category": "simple_qa", "estimated_input_tokens": 15, "estimated_output_tokens": 10},
        {"prompt": "次の数列の次の数は？ 2, 4, 8, 16, ?",
         "category": "simple_qa", "estimated_input_tokens": 20, "estimated_output_tokens": 5},
        {"prompt": "Pythonでリストの長さを取得する関数は？",
         "category": "simple_qa", "estimated_input_tokens": 15, "estimated_output_tokens": 10},
        {"prompt": "HTTPステータスコード404の意味は？",
         "category": "simple_qa", "estimated_input_tokens": 12, "estimated_output_tokens": 15},
        {"prompt": "ISO 8601の日付フォーマットの例を1つ挙げてください。",
         "category": "simple_qa", "estimated_input_tokens": 18, "estimated_output_tokens": 10},
        {"prompt": "次の文の感情を分類してください: '今日は最高の日だ！'",
         "category": "classification", "estimated_input_tokens": 20, "estimated_output_tokens": 5},
        {"prompt": "CSSでテキストを中央揃えにするプロパティは？",
         "category": "simple_qa", "estimated_input_tokens": 15, "estimated_output_tokens": 10},
        {"prompt": "SQLでテーブルの全行を取得するクエリは？",
         "category": "simple_qa", "estimated_input_tokens": 15, "estimated_output_tokens": 10},
    ]

    for i in range(30):
        template = light_templates[i % len(light_templates)].copy()
        template["id"] = f"light_{i+1:03d}"
        template["difficulty"] = "light"
        template["routing_decision"] = "local"  # Hayabusaで処理
        tasks.append(template)

    # Medium tasks（50件）: コード生成、要約、分析
    # 一部はHayabusaで処理可能、複雑なものはClaude
    medium_templates = [
        {"prompt": "Pythonでバブルソートを実装してください。型ヒント付きで。",
         "category": "code_generation", "estimated_input_tokens": 25, "estimated_output_tokens": 150},
        {"prompt": "以下の関数のバグを修正してください:\ndef add(a, b): return a - b",
         "category": "code_review", "estimated_input_tokens": 30, "estimated_output_tokens": 80},
        {"prompt": "REST APIのベストプラクティスを5つ挙げてください。",
         "category": "explanation", "estimated_input_tokens": 15, "estimated_output_tokens": 200},
        {"prompt": "Docker ComposeでRedisとPostgreSQLを起動するYAMLを書いてください。",
         "category": "code_generation", "estimated_input_tokens": 20, "estimated_output_tokens": 180},
        {"prompt": "Gitのrebaseとmergeの違いを説明し、それぞれの使い分けを述べてください。",
         "category": "explanation", "estimated_input_tokens": 25, "estimated_output_tokens": 250},
        {"prompt": "TypeScriptのジェネリクスの使い方を例とともに説明してください。",
         "category": "explanation", "estimated_input_tokens": 20, "estimated_output_tokens": 200},
        {"prompt": "N+1問題とは何か、どう解決するかをORMの例で説明してください。",
         "category": "explanation", "estimated_input_tokens": 20, "estimated_output_tokens": 200},
        {"prompt": "Reactのカスタムフックを使ったフォームバリデーションの実装例を示してください。",
         "category": "code_generation", "estimated_input_tokens": 25, "estimated_output_tokens": 300},
        {"prompt": "マイクロサービスアーキテクチャのメリットとデメリットを比較してください。",
         "category": "analysis", "estimated_input_tokens": 18, "estimated_output_tokens": 250},
        {"prompt": "OAuth 2.0のAuthorization Code Flowを図を使わずに説明してください。",
         "category": "explanation", "estimated_input_tokens": 20, "estimated_output_tokens": 300},
    ]

    for i in range(50):
        template = medium_templates[i % len(medium_templates)].copy()
        template["id"] = f"medium_{i+1:03d}"
        template["difficulty"] = "medium"
        # mediumの60%はローカル、40%はClaude
        template["routing_decision"] = "local" if random.random() < 0.6 else "escalate"
        tasks.append(template)

    # Heavy tasks（20件）: 複雑な推論、長文生成、マルチステップ
    # 基本的にClaudeにエスカレーション
    heavy_templates = [
        {"prompt": "分散システムにおけるCAP定理について、各トレードオフの実例を含めて詳細に説明し、"
                   "最新のNewSQL（CockroachDB、TiDB等）がどうアプローチしているか論じてください。",
         "category": "deep_analysis", "estimated_input_tokens": 60, "estimated_output_tokens": 800},
        {"prompt": "Kubernetesクラスタの本番運用設計書を作成してください。HA構成、監視、ログ、"
                   "セキュリティ、CI/CD、コスト最適化の各観点を含めること。",
         "category": "document_generation", "estimated_input_tokens": 50, "estimated_output_tokens": 1200},
        {"prompt": "GPTアーキテクチャ（Transformer Decoder）の数式を含めた技術解説を書いてください。"
                   "Self-Attention、FFN、Layer Norm、位置エンコーディングの各コンポーネントを網羅すること。",
         "category": "technical_writing", "estimated_input_tokens": 55, "estimated_output_tokens": 1000},
        {"prompt": "Rustのメモリ安全性モデル（所有権、借用、ライフタイム）を、C++のスマートポインタと"
                   "比較して論じてください。具体的なコード例とコンパイルエラー例を含めること。",
         "category": "comparative_analysis", "estimated_input_tokens": 50, "estimated_output_tokens": 900},
        {"prompt": "ゼロからReact風の仮想DOM差分アルゴリズムをTypeScriptで実装してください。"
                   "createElement、diff、patch、コンポーネントライフサイクルを含む完全な実装。",
         "category": "complex_code", "estimated_input_tokens": 45, "estimated_output_tokens": 1500},
    ]

    for i in range(20):
        template = heavy_templates[i % len(heavy_templates)].copy()
        template["id"] = f"heavy_{i+1:03d}"
        template["difficulty"] = "heavy"
        template["routing_decision"] = "escalate"  # 常にClaudeへ
        tasks.append(template)

    random.shuffle(tasks)
    return tasks


# ── Hayabusa classify 呼び出し ────────────────────────────────────────

async def classify_task(
    session: aiohttp.ClientSession,
    hayabusa_url: str,
    prompt: str,
) -> tuple[str, float]:
    """Hayabusaのclassifyエンドポイントでタスクの難易度を判定。"""
    # classify用のプロンプト: ローカルで処理可能かを判定
    classify_prompt = (
        f"Classify the following task as 'local' (can be handled by a small local LLM) "
        f"or 'escalate' (requires a large cloud model). "
        f"Reply with only 'local' or 'escalate'.\n\nTask: {prompt}"
    )

    payload = {
        "model": "default",
        "messages": [{"role": "user", "content": classify_prompt}],
        "max_tokens": 10,
        "temperature": 0,
        "stream": False,
    }

    t0 = time.perf_counter()
    try:
        async with session.post(
            f"{hayabusa_url}/v1/chat/completions",
            json=payload,
            timeout=aiohttp.ClientTimeout(total=30),
        ) as resp:
            elapsed = (time.perf_counter() - t0) * 1000
            if resp.status != 200:
                return "escalate", elapsed  # フォールバック: エスカレーション

            data = await resp.json()
            content = data.get("choices", [{}])[0].get("message", {}).get("content", "").strip().lower()

            if "local" in content:
                return "local", elapsed
            else:
                return "escalate", elapsed

    except Exception:
        elapsed = (time.perf_counter() - t0) * 1000
        return "escalate", elapsed


# ── コスト計算 ────────────────────────────────────────────────────────

def calculate_costs(tasks: list[dict], routing_results: list[dict]) -> dict:
    """Claude-only vs KAJIBA統合のコストを計算。"""

    # Claude-only: 全タスクをClaude APIに送信
    total_input_tokens_claude = 0
    total_output_tokens_claude = 0

    # KAJIBA統合: classify → route/escalate
    total_input_tokens_kajiba = 0
    total_output_tokens_kajiba = 0
    classify_tokens = 0  # classifyに使ったトークン

    local_count = 0
    escalate_count = 0

    for task, routing in zip(tasks, routing_results):
        input_tokens = task["estimated_input_tokens"]
        output_tokens = task["estimated_output_tokens"]

        # Claude-only: 全タスクがClaudeに行く
        total_input_tokens_claude += input_tokens
        total_output_tokens_claude += output_tokens

        # KAJIBA: classifyのコスト（ローカルなのでClaude APIコストは0）
        # classifyは約50トークン入力、5トークン出力をローカルで処理
        classify_input = 50
        classify_output = 5
        classify_tokens += classify_input + classify_output

        decision = routing["decision"]
        if decision == "local":
            # ローカルで処理: Claude APIコストは0
            local_count += 1
        else:
            # Claudeにエスカレーション
            total_input_tokens_kajiba += input_tokens
            total_output_tokens_kajiba += output_tokens
            escalate_count += 1

    # コスト計算
    claude_only_input_cost = total_input_tokens_claude / 1_000_000 * CLAUDE_INPUT_COST_PER_MTOK
    claude_only_output_cost = total_output_tokens_claude / 1_000_000 * CLAUDE_OUTPUT_COST_PER_MTOK
    claude_only_total = claude_only_input_cost + claude_only_output_cost

    kajiba_input_cost = total_input_tokens_kajiba / 1_000_000 * CLAUDE_INPUT_COST_PER_MTOK
    kajiba_output_cost = total_output_tokens_kajiba / 1_000_000 * CLAUDE_OUTPUT_COST_PER_MTOK
    kajiba_total = kajiba_input_cost + kajiba_output_cost

    total_tokens_claude = total_input_tokens_claude + total_output_tokens_claude
    total_tokens_kajiba = total_input_tokens_kajiba + total_output_tokens_kajiba

    reduction_rate = 1.0 - (total_tokens_kajiba / total_tokens_claude) if total_tokens_claude > 0 else 0

    return {
        "total_tasks": len(tasks),
        "routing": {
            "local": local_count,
            "escalate": escalate_count,
            "local_rate": round(local_count / len(tasks), 4) if tasks else 0,
        },
        "claude_only": {
            "total_tokens": total_tokens_claude,
            "input_tokens": total_input_tokens_claude,
            "output_tokens": total_output_tokens_claude,
            "cost_usd": round(claude_only_total, 6),
            "input_cost_usd": round(claude_only_input_cost, 6),
            "output_cost_usd": round(claude_only_output_cost, 6),
        },
        "kajiba": {
            "total_tokens": total_tokens_kajiba,
            "input_tokens": total_input_tokens_kajiba,
            "output_tokens": total_output_tokens_kajiba,
            "classify_tokens_local": classify_tokens,
            "cost_usd": round(kajiba_total, 6),
            "input_cost_usd": round(kajiba_input_cost, 6),
            "output_cost_usd": round(kajiba_output_cost, 6),
        },
        "reduction": {
            "token_reduction_rate": round(reduction_rate, 4),
            "cost_reduction_rate": round(1.0 - (kajiba_total / claude_only_total), 4) if claude_only_total > 0 else 0,
            "tokens_saved": total_tokens_claude - total_tokens_kajiba,
            "cost_saved_usd": round(claude_only_total - kajiba_total, 6),
        },
    }


# ── メイン処理 ────────────────────────────────────────────────────────

async def main():
    parser = argparse.ArgumentParser(
        description="Experiment C: Token Cost Reduction — Claude-only vs KAJIBA統合",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--hayabusa-url", default="http://localhost:8080",
                        help="Hayabusa server URL (default: http://localhost:8080)")
    parser.add_argument("--tasks", type=str, default=None,
                        help="Path to tasks JSONL file (optional, generates 100 tasks if not provided)")
    parser.add_argument("--output", type=str, default=None,
                        help="Output JSON path (default: auto-generated)")
    parser.add_argument("--simulate-only", action="store_true",
                        help="Use pre-defined routing decisions instead of calling Hayabusa")
    args = parser.parse_args()

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    # タスク読み込みまたは生成
    if args.tasks:
        tasks = []
        with open(args.tasks, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    tasks.append(json.loads(line))
        print(f"Loaded {len(tasks)} tasks from {args.tasks}", file=sys.stderr)
    else:
        tasks = generate_tasks()
        print(f"Generated {len(tasks)} tasks (30 light, 50 medium, 20 heavy)", file=sys.stderr)

    # 難易度別の集計
    by_difficulty = {}
    for task in tasks:
        d = task.get("difficulty", "unknown")
        by_difficulty.setdefault(d, 0)
        by_difficulty[d] += 1
    print(f"Tasks by difficulty: {by_difficulty}", file=sys.stderr)

    # ルーティング判定
    routing_results = []

    if args.simulate_only:
        # シミュレーション: 事前定義のルーティング結果を使用
        print("Using simulated routing decisions (--simulate-only)", file=sys.stderr)
        for task in tasks:
            routing_results.append({
                "task_id": task["id"],
                "decision": task.get("routing_decision", "escalate"),
                "classify_latency_ms": 0,
                "source": "simulated",
            })
    else:
        # Hayabusa classify を呼び出し
        print(f"Calling Hayabusa classify at {args.hayabusa_url}...", file=sys.stderr)

        # ヘルスチェック
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(
                    f"{args.hayabusa_url}/v1/models",
                    timeout=aiohttp.ClientTimeout(total=5),
                ) as resp:
                    if resp.status != 200:
                        print(f"WARNING: Hayabusa returned status {resp.status}. "
                              f"Falling back to simulated routing.", file=sys.stderr)
                        args.simulate_only = True
        except Exception as e:
            print(f"WARNING: Cannot reach Hayabusa at {args.hayabusa_url}: {e}", file=sys.stderr)
            print("Falling back to simulated routing.", file=sys.stderr)
            args.simulate_only = True

        if args.simulate_only:
            # フォールバック
            for task in tasks:
                routing_results.append({
                    "task_id": task["id"],
                    "decision": task.get("routing_decision", "escalate"),
                    "classify_latency_ms": 0,
                    "source": "simulated_fallback",
                })
        else:
            async with aiohttp.ClientSession() as session:
                for i, task in enumerate(tasks):
                    if (i + 1) % 10 == 0 or i == 0:
                        print(f"  Classifying [{i+1}/{len(tasks)}]...", file=sys.stderr)

                    decision, latency = await classify_task(
                        session, args.hayabusa_url, task["prompt"]
                    )

                    routing_results.append({
                        "task_id": task["id"],
                        "decision": decision,
                        "classify_latency_ms": round(latency, 2),
                        "source": "hayabusa_classify",
                    })

    # コスト計算
    cost_analysis = calculate_costs(tasks, routing_results)

    # 難易度別のブレークダウン
    breakdown = {}
    for task, routing in zip(tasks, routing_results):
        d = task.get("difficulty", "unknown")
        if d not in breakdown:
            breakdown[d] = {"count": 0, "local": 0, "escalate": 0,
                            "input_tokens": 0, "output_tokens": 0}
        breakdown[d]["count"] += 1
        breakdown[d][routing["decision"]] += 1
        breakdown[d]["input_tokens"] += task["estimated_input_tokens"]
        breakdown[d]["output_tokens"] += task["estimated_output_tokens"]

    # classify レイテンシ統計
    classify_latencies = [r["classify_latency_ms"] for r in routing_results if r["classify_latency_ms"] > 0]
    classify_stats = {}
    if classify_latencies:
        classify_stats = {
            "avg_ms": round(statistics.mean(classify_latencies), 2),
            "p50_ms": round(sorted(classify_latencies)[len(classify_latencies) // 2], 2),
            "p95_ms": round(sorted(classify_latencies)[int(len(classify_latencies) * 0.95)], 2),
            "total_classify_time_sec": round(sum(classify_latencies) / 1000, 2),
        }

    # 出力
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    output_path = Path(args.output) if args.output else RESULTS_DIR / f"exp_c_token_cost_{timestamp}.json"

    output_data = {
        "experiment": "exp_c_token_cost",
        "timestamp": timestamp,
        "config": {
            "hayabusa_url": args.hayabusa_url,
            "simulate_only": args.simulate_only,
            "claude_input_cost_per_mtok": CLAUDE_INPUT_COST_PER_MTOK,
            "claude_output_cost_per_mtok": CLAUDE_OUTPUT_COST_PER_MTOK,
        },
        "cost_analysis": cost_analysis,
        "breakdown_by_difficulty": breakdown,
        "classify_latency": classify_stats,
        "routing_results": routing_results,
    }

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output_data, f, indent=2, ensure_ascii=False)

    # サマリー表示
    print(f"\nResults saved to: {output_path}", file=sys.stderr)
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Token Cost Reduction Analysis", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)
    r = cost_analysis["reduction"]
    c = cost_analysis["claude_only"]
    k = cost_analysis["kajiba"]
    print(f"  Claude-only:  {c['total_tokens']:>8} tokens  ${c['cost_usd']:.4f}", file=sys.stderr)
    print(f"  KAJIBA:       {k['total_tokens']:>8} tokens  ${k['cost_usd']:.4f}", file=sys.stderr)
    print(f"  Token reduction: {r['token_reduction_rate']:.1%}", file=sys.stderr)
    print(f"  Cost reduction:  {r['cost_reduction_rate']:.1%}", file=sys.stderr)
    print(f"  Cost saved:      ${r['cost_saved_usd']:.4f}", file=sys.stderr)
    routing = cost_analysis["routing"]
    print(f"  Routing: {routing['local']} local, {routing['escalate']} escalate "
          f"({routing['local_rate']:.0%} local)", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)

    print(json.dumps(output_data, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    asyncio.run(main())
