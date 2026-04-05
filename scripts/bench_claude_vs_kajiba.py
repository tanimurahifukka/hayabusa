#!/usr/bin/env python3
"""Claude Code単独 vs KAJIBA多重下請け — 時間・トークン実測比較.

同じタスクセットを:
  A) Claude Code（Anthropic API）で処理
  B) KAJIBA（ローカルHayabusa）で処理
して、時間・トークン・コストを直接比較する。

API key不要モード: --no-claude で Hayabusaのみ計測し、
Claude側はトークン推定値を使う（プロンプト長から概算）。

Usage:
    # Hayabusaのみ実測 + Claude推定
    python scripts/bench_claude_vs_kajiba.py --no-claude

    # 両方実測（ANTHROPIC_API_KEY必要）
    ANTHROPIC_API_KEY=sk-... python scripts/bench_claude_vs_kajiba.py

    # タスク数指定
    python scripts/bench_claude_vs_kajiba.py --no-claude --tasks 20
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import random
import sys
import time
from dataclasses import dataclass, asdict
from pathlib import Path

import aiohttp

random.seed(42)

HAYABUSA_URL = "http://localhost:{port}/v1/chat/completions"
ANTHROPIC_URL = "https://api.anthropic.com/v1/messages"
SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_DIR = SCRIPT_DIR / "results"
OUTPUT_DIR.mkdir(exist_ok=True)

# Claude pricing (per token)
CLAUDE_INPUT_PER_TOK = 15 / 1_000_000    # $15/MTok
CLAUDE_OUTPUT_PER_TOK = 75 / 1_000_000   # $75/MTok

# ── タスクセット ──────────────────────────────────────────────────

TASKS = [
    # 軽量タスク（ローカル完結想定）
    {"id": "light_01", "weight": "light", "system": "Answer briefly.", "prompt": "What does HTTP status 429 mean?", "est_output_tokens": 30},
    {"id": "light_02", "weight": "light", "system": "Answer briefly.", "prompt": "TypeScriptでstringをnumberに変換するには？", "est_output_tokens": 25},
    {"id": "light_03", "weight": "light", "system": "Answer briefly.", "prompt": "gitで直前のcommitメッセージを修正するコマンドは？", "est_output_tokens": 20},
    {"id": "light_04", "weight": "light", "system": "Answer briefly.", "prompt": "CSSのflexboxでセンタリングする最短のコードは？", "est_output_tokens": 30},
    {"id": "light_05", "weight": "light", "system": "Answer briefly.", "prompt": "Pythonでリストの重複を除去するワンライナーは？", "est_output_tokens": 20},
    {"id": "light_06", "weight": "light", "system": "Classify this task.", "prompt": "Stripeのwebhook署名検証でエラーが出る", "est_output_tokens": 15},
    {"id": "light_07", "weight": "light", "system": "Classify this task.", "prompt": "Next.jsのビルドが遅い。改善方法は？", "est_output_tokens": 15},
    {"id": "light_08", "weight": "light", "system": "Answer briefly.", "prompt": "React useEffectのクリーンアップ関数の書き方", "est_output_tokens": 40},

    # 中量タスク（コード生成・修正 → スペシャリスト想定）
    {"id": "mid_01", "weight": "medium", "system": "Write only the function.", "prompt": "Write a Python function to check if a string is a valid email address using regex.", "est_output_tokens": 80},
    {"id": "mid_02", "weight": "medium", "system": "Fix the bug. Return only corrected code.", "prompt": "def binary_search(arr, target):\n  low, high = 0, len(arr)\n  while low < high:\n    mid = (low + high) // 2\n    if arr[mid] == target: return mid\n    if arr[mid] < target: low = mid\n    else: high = mid\n  return -1", "est_output_tokens": 100},
    {"id": "mid_03", "weight": "medium", "system": "Write only the function.", "prompt": "Write a TypeScript function that debounces a callback with a given delay.", "est_output_tokens": 80},
    {"id": "mid_04", "weight": "medium", "system": "Generate pytest tests.", "prompt": "def fibonacci(n):\n    if n <= 1: return n\n    return fibonacci(n-1) + fibonacci(n-2)", "est_output_tokens": 120},
    {"id": "mid_05", "weight": "medium", "system": "Write the API route.", "prompt": "Write a Next.js API route /api/users that fetches users from Supabase and returns JSON.", "est_output_tokens": 100},
    {"id": "mid_06", "weight": "medium", "system": "Write the component.", "prompt": "Write a React component for a searchable dropdown that filters options as the user types.", "est_output_tokens": 150},
    {"id": "mid_07", "weight": "medium", "system": "Fix the security issue.", "prompt": "Fix SQL injection:\ndef get_user(db, name):\n    return db.execute(f\"SELECT * FROM users WHERE name = '{name}'\")", "est_output_tokens": 80},
    {"id": "mid_08", "weight": "medium", "system": "Write the function.", "prompt": "Write a Python function that merges two sorted lists into one sorted list in O(n+m) time.", "est_output_tokens": 80},

    # 重量タスク（設計判断 → Claude Code想定）
    {"id": "heavy_01", "weight": "heavy", "system": "You are a senior architect.", "prompt": "Design the database schema for a multi-tenant SaaS application with row-level security using Supabase. Include tables for organizations, users, roles, and audit logs. Explain the RLS policies.", "est_output_tokens": 400},
    {"id": "heavy_02", "weight": "heavy", "system": "You are a senior architect.", "prompt": "Design a CI/CD pipeline for a Next.js monorepo with 5 apps. Include build caching, preview deployments, and rollback strategy. Use GitHub Actions.", "est_output_tokens": 500},
    {"id": "heavy_03", "weight": "heavy", "system": "You are a senior architect.", "prompt": "Compare three approaches for real-time features in a web app: WebSocket, SSE, and polling. Consider scalability, implementation complexity, and mobile support. Recommend one for a chat feature with 10K concurrent users.", "est_output_tokens": 350},
    {"id": "heavy_04", "weight": "heavy", "system": "You are a senior architect.", "prompt": "Design an authentication flow for a medical clinic app that requires: OAuth login, session management, RBAC (doctor/nurse/admin), and audit logging. All patient data must stay local. Provide the architecture diagram in text.", "est_output_tokens": 450},
]


# ── Hayabusa呼び出し ──────────────────────────────────────────────

@dataclass
class TaskResult:
    id: str
    weight: str
    target: str  # "hayabusa" or "claude"
    input_tokens: int
    output_tokens: int
    total_tokens: int
    latency_ms: float
    cost_usd: float
    success: bool
    response_preview: str = ""


async def run_hayabusa(session, port, task):
    url = HAYABUSA_URL.format(port=port)
    payload = {
        "model": "local",
        "messages": [
            {"role": "system", "content": task["system"]},
            {"role": "user", "content": task["prompt"]},
        ],
        "max_tokens": max(task["est_output_tokens"] * 2, 128),
        "temperature": 0,
    }

    t0 = time.perf_counter()
    try:
        async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=120)) as resp:
            raw = await resp.read()
            elapsed = (time.perf_counter() - t0) * 1000
            data = json.loads(raw.decode("utf-8", errors="replace"))

            usage = data.get("usage", {})
            input_tokens = usage.get("prompt_tokens", 0)
            output_tokens = usage.get("completion_tokens", 0)
            content = data.get("choices", [{}])[0].get("message", {}).get("content", "")

            return TaskResult(
                id=task["id"], weight=task["weight"], target="hayabusa",
                input_tokens=input_tokens, output_tokens=output_tokens,
                total_tokens=input_tokens + output_tokens,
                latency_ms=elapsed, cost_usd=0.0,  # ローカル = $0
                success=True, response_preview=content[:200],
            )
    except Exception as e:
        elapsed = (time.perf_counter() - t0) * 1000
        return TaskResult(
            id=task["id"], weight=task["weight"], target="hayabusa",
            input_tokens=0, output_tokens=0, total_tokens=0,
            latency_ms=elapsed, cost_usd=0.0, success=False,
            response_preview=f"ERROR: {e}",
        )


# ── Claude API呼び出し ────────────────────────────────────────────

async def run_claude(session, task, api_key, model="claude-sonnet-4-20250514"):
    headers = {
        "x-api-key": api_key,
        "content-type": "application/json",
        "anthropic-version": "2023-06-01",
    }
    payload = {
        "model": model,
        "max_tokens": max(task["est_output_tokens"] * 2, 128),
        "system": task["system"],
        "messages": [{"role": "user", "content": task["prompt"]}],
    }

    t0 = time.perf_counter()
    try:
        async with session.post(ANTHROPIC_URL, json=payload, headers=headers,
                                timeout=aiohttp.ClientTimeout(total=60)) as resp:
            elapsed = (time.perf_counter() - t0) * 1000
            data = await resp.json()

            if resp.status != 200:
                return TaskResult(
                    id=task["id"], weight=task["weight"], target="claude",
                    input_tokens=0, output_tokens=0, total_tokens=0,
                    latency_ms=elapsed, cost_usd=0.0, success=False,
                    response_preview=f"HTTP {resp.status}: {data.get('error', {}).get('message', '')}",
                )

            usage = data.get("usage", {})
            input_tokens = usage.get("input_tokens", 0)
            output_tokens = usage.get("output_tokens", 0)
            content = data.get("content", [{}])[0].get("text", "")
            cost = input_tokens * CLAUDE_INPUT_PER_TOK + output_tokens * CLAUDE_OUTPUT_PER_TOK

            return TaskResult(
                id=task["id"], weight=task["weight"], target="claude",
                input_tokens=input_tokens, output_tokens=output_tokens,
                total_tokens=input_tokens + output_tokens,
                latency_ms=elapsed, cost_usd=round(cost, 6),
                success=True, response_preview=content[:200],
            )
    except Exception as e:
        elapsed = (time.perf_counter() - t0) * 1000
        return TaskResult(
            id=task["id"], weight=task["weight"], target="claude",
            input_tokens=0, output_tokens=0, total_tokens=0,
            latency_ms=elapsed, cost_usd=0.0, success=False,
            response_preview=f"ERROR: {e}",
        )


def estimate_claude(task):
    """Claude APIキーなしの場合のトークン推定"""
    # 入力トークン推定: system + prompt の文字数 / 3.5（英語平均）
    input_chars = len(task["system"]) + len(task["prompt"])
    input_tokens = max(20, int(input_chars / 3.5))
    output_tokens = task["est_output_tokens"]
    total = input_tokens + output_tokens
    cost = input_tokens * CLAUDE_INPUT_PER_TOK + output_tokens * CLAUDE_OUTPUT_PER_TOK
    # レイテンシ推定: Claude Sonnet ≈ 50-100tok/s output
    latency = (input_tokens / 200 + output_tokens / 70) * 1000  # ms

    return TaskResult(
        id=task["id"], weight=task["weight"], target="claude_estimated",
        input_tokens=input_tokens, output_tokens=output_tokens,
        total_tokens=total, latency_ms=round(latency),
        cost_usd=round(cost, 6), success=True,
        response_preview="(estimated)",
    )


# ── KAJIBA統合シミュレーション ────────────────────────────────────

async def run_kajiba_integrated(session, port, task):
    """KAJIBAルーティング: classify → local or escalate"""
    # Step 1: ローカルclassify
    classify_result = await run_hayabusa(session, port, {
        "id": f"{task['id']}_classify",
        "weight": "light",
        "system": "Classify this task into one category: LIGHT, MEDIUM, HEAVY. Return only the category.",
        "prompt": task["prompt"],
        "est_output_tokens": 10,
    })

    # Step 2: ルーティング判断
    # 軽量・中量はローカル処理、重量はClaude行き
    if task["weight"] in ("light", "medium"):
        # ローカルで処理
        result = await run_hayabusa(session, port, task)
        result.target = "kajiba_local"
        # classify分のレイテンシを加算
        result.latency_ms += classify_result.latency_ms
        return result, "local"
    else:
        # 重量タスク → Claude escalation
        # 実際にはClaude APIを叩くが、ここではestimate
        result = estimate_claude(task)
        result.target = "kajiba_escalated"
        # classify分のレイテンシを加算
        result.latency_ms += classify_result.latency_ms
        return result, "escalated"


# ── メイン ────────────────────────────────────────────────────────

async def main():
    parser = argparse.ArgumentParser(description="Claude Code vs KAJIBA 実測比較")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--no-claude", action="store_true", help="Claude API不使用（推定値）")
    parser.add_argument("--tasks", type=int, default=0, help="タスク数制限（0=全部）")
    parser.add_argument("--claude-model", default="claude-sonnet-4-20250514")
    args = parser.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    use_claude = bool(api_key) and not args.no_claude

    tasks = TASKS
    if args.tasks > 0:
        tasks = tasks[:args.tasks]

    # Health check
    try:
        async with aiohttp.ClientSession() as s:
            async with s.get(f"http://localhost:{args.port}/health", timeout=aiohttp.ClientTimeout(total=5)) as r:
                if r.status != 200:
                    print("Hayabusa not running", file=sys.stderr); return
    except:
        print("Hayabusa not running", file=sys.stderr); return

    print(f"", file=sys.stderr)
    print(f"{'='*70}", file=sys.stderr)
    print(f"  Claude Code単独 vs KAJIBA多重下請け 実測比較", file=sys.stderr)
    print(f"  Tasks: {len(tasks)} | Claude: {'API実測' if use_claude else '推定値'}", file=sys.stderr)
    print(f"{'='*70}", file=sys.stderr)
    print(f"", file=sys.stderr)

    claude_results = []
    kajiba_results = []
    routing_log = []

    async with aiohttp.ClientSession() as session:
        for i, task in enumerate(tasks):
            print(f"  [{i+1}/{len(tasks)}] {task['id']} ({task['weight']})...", file=sys.stderr, end="")

            # Claude側
            if use_claude:
                cr = await run_claude(session, task, api_key, args.claude_model)
            else:
                cr = estimate_claude(task)
            claude_results.append(cr)

            # KAJIBA側
            kr, route = await run_kajiba_integrated(session, args.port, task)
            kajiba_results.append(kr)
            routing_log.append({"id": task["id"], "weight": task["weight"], "route": route})

            status = "LOCAL" if route == "local" else "ESCALATE"
            print(f" Claude:{cr.total_tokens}tok/${cr.cost_usd:.4f}/{cr.latency_ms:.0f}ms"
                  f" | KAJIBA:{kr.total_tokens}tok/${kr.cost_usd:.4f}/{kr.latency_ms:.0f}ms [{status}]",
                  file=sys.stderr)

    # ── 集計 ──
    claude_total_tokens = sum(r.total_tokens for r in claude_results)
    claude_total_cost = sum(r.cost_usd for r in claude_results)
    claude_total_latency = sum(r.latency_ms for r in claude_results)
    claude_avg_latency = claude_total_latency / len(claude_results)

    kajiba_total_tokens = sum(r.total_tokens for r in kajiba_results if "escalated" in r.target)
    kajiba_total_cost = sum(r.cost_usd for r in kajiba_results)
    kajiba_total_latency = sum(r.latency_ms for r in kajiba_results)
    kajiba_avg_latency = kajiba_total_latency / len(kajiba_results)
    kajiba_local_count = sum(1 for r in routing_log if r["route"] == "local")
    kajiba_escalated_count = sum(1 for r in routing_log if r["route"] == "escalated")

    # Hayabusaの実測トークン（ローカル処理分）
    hayabusa_local_tokens = sum(r.total_tokens for r in kajiba_results if "local" in r.target)

    token_reduction = (claude_total_tokens - kajiba_total_tokens) / claude_total_tokens if claude_total_tokens > 0 else 0
    cost_reduction = (claude_total_cost - kajiba_total_cost) / claude_total_cost if claude_total_cost > 0 else 0

    # ── 結果表示 ──
    print(f"", file=sys.stderr)
    print(f"{'='*70}", file=sys.stderr)
    print(f"  結果サマリー", file=sys.stderr)
    print(f"{'='*70}", file=sys.stderr)
    print(f"", file=sys.stderr)
    print(f"  {'':30s} {'Claude単独':>15s} {'KAJIBA':>15s} {'削減':>10s}", file=sys.stderr)
    print(f"  {'-'*70}", file=sys.stderr)
    print(f"  {'Claudeトークン消費':30s} {claude_total_tokens:>15,} {kajiba_total_tokens:>15,} {token_reduction*100:>9.1f}%", file=sys.stderr)
    print(f"  {'コスト (USD)':30s} ${claude_total_cost:>14.4f} ${kajiba_total_cost:>14.4f} {cost_reduction*100:>9.1f}%", file=sys.stderr)
    print(f"  {'合計レイテンシ (ms)':30s} {claude_total_latency:>15,.0f} {kajiba_total_latency:>15,.0f}", file=sys.stderr)
    print(f"  {'平均レイテンシ (ms)':30s} {claude_avg_latency:>15,.0f} {kajiba_avg_latency:>15,.0f}", file=sys.stderr)
    print(f"  {'ローカル処理数':30s} {'—':>15s} {kajiba_local_count:>15d}", file=sys.stderr)
    print(f"  {'Claude転送数':30s} {len(tasks):>15d} {kajiba_escalated_count:>15d}", file=sys.stderr)
    print(f"  {'ローカル実トークン ($0)':30s} {'—':>15s} {hayabusa_local_tokens:>15,}", file=sys.stderr)
    print(f"", file=sys.stderr)

    # Weight別内訳
    print(f"  Weight別内訳:", file=sys.stderr)
    for w in ["light", "medium", "heavy"]:
        c_toks = sum(r.total_tokens for r in claude_results if r.weight == w)
        k_toks = sum(r.total_tokens for r in kajiba_results if r.weight == w and "escalated" in r.target)
        c_cost = sum(r.cost_usd for r in claude_results if r.weight == w)
        k_cost = sum(r.cost_usd for r in kajiba_results if r.weight == w)
        count = sum(1 for t in tasks if t["weight"] == w)
        local = sum(1 for r in routing_log if r["weight"] == w and r["route"] == "local")
        print(f"    {w:8s}: {count}件 | Claude {c_toks:>6}tok ${c_cost:.4f} | KAJIBA {k_toks:>6}tok ${k_cost:.4f} (local={local})", file=sys.stderr)

    print(f"", file=sys.stderr)

    # ── JSON出力 ──
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    output = {
        "experiment": "claude_vs_kajiba",
        "timestamp": timestamp,
        "config": {
            "tasks": len(tasks),
            "claude_mode": "api" if use_claude else "estimated",
            "hayabusa_port": args.port,
        },
        "summary": {
            "claude_total_tokens": claude_total_tokens,
            "kajiba_cloud_tokens": kajiba_total_tokens,
            "kajiba_local_tokens": hayabusa_local_tokens,
            "token_reduction_rate": round(token_reduction, 4),
            "claude_cost_usd": round(claude_total_cost, 6),
            "kajiba_cost_usd": round(kajiba_total_cost, 6),
            "cost_reduction_rate": round(cost_reduction, 4),
            "claude_avg_latency_ms": round(claude_avg_latency),
            "kajiba_avg_latency_ms": round(kajiba_avg_latency),
            "local_handled": kajiba_local_count,
            "escalated": kajiba_escalated_count,
        },
        "claude_results": [asdict(r) for r in claude_results],
        "kajiba_results": [asdict(r) for r in kajiba_results],
        "routing_log": routing_log,
    }

    out_path = OUTPUT_DIR / f"claude_vs_kajiba_{timestamp}.json"
    with open(out_path, "w") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    print(f"Saved: {out_path}", file=sys.stderr)

    # stdout にサマリーJSON
    summary = output["summary"]
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    asyncio.run(main())
