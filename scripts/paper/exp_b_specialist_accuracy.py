#!/usr/bin/env python3
"""Experiment B: Specialist vs Generalist 精度比較.

ドメイン特化モデル（Specialist）と汎用モデル（Generalist）の精度を
キーワードマッチングで比較する。テストセットはJSONLファイルまたはプログラム生成。

Usage:
    python scripts/paper/exp_b_specialist_accuracy.py --domain stripe
    python scripts/paper/exp_b_specialist_accuracy.py --domain supabase --testset my_tests.jsonl
    python scripts/paper/exp_b_specialist_accuracy.py --domain orca --generate-only
    python scripts/paper/exp_b_specialist_accuracy.py --domain stripe --specialist-url http://localhost:8080 --generalist-url http://localhost:8081
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import statistics
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import aiohttp

# ── 再現性 ───────────────────────────────────────────────────────────
random.seed(42)

SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "results"


# ── テストセット生成 ──────────────────────────────────────────────────

def generate_testset(domain: str) -> list[dict]:
    """ドメイン別のテストセットをプログラム生成する（各10問）。"""

    if domain == "stripe":
        return [
            {
                "id": "stripe_01",
                "prompt": "How do I create a PaymentIntent with automatic confirmation and capture in Stripe?",
                "expected_keywords": ["PaymentIntent", "create", "confirm", "capture", "automatic"],
                "domain": "stripe",
            },
            {
                "id": "stripe_02",
                "prompt": "Explain how Stripe webhook signature verification works. What header contains the signature?",
                "expected_keywords": ["Stripe-Signature", "webhook", "verify", "secret", "timestamp"],
                "domain": "stripe",
            },
            {
                "id": "stripe_03",
                "prompt": "How do I set up Stripe Connect with Standard accounts? What's the OAuth flow?",
                "expected_keywords": ["Connect", "Standard", "OAuth", "account", "authorize"],
                "domain": "stripe",
            },
            {
                "id": "stripe_04",
                "prompt": "What is the difference between Stripe Checkout and Elements? When should I use each?",
                "expected_keywords": ["Checkout", "Elements", "hosted", "embedded", "customiz"],
                "domain": "stripe",
            },
            {
                "id": "stripe_05",
                "prompt": "How do I handle idempotency in Stripe API calls? What header do I use?",
                "expected_keywords": ["Idempotency-Key", "header", "retry", "idempoten"],
                "domain": "stripe",
            },
            {
                "id": "stripe_06",
                "prompt": "Explain Stripe's subscription billing cycle. How do proration and invoicing work?",
                "expected_keywords": ["subscription", "invoice", "proration", "billing", "cycle"],
                "domain": "stripe",
            },
            {
                "id": "stripe_07",
                "prompt": "How do I implement Stripe SCA (Strong Customer Authentication) for European customers?",
                "expected_keywords": ["SCA", "3D Secure", "authentication", "PSD2", "PaymentIntent"],
                "domain": "stripe",
            },
            {
                "id": "stripe_08",
                "prompt": "What are Stripe price objects? How do I create recurring vs one-time prices?",
                "expected_keywords": ["Price", "recurring", "one_time", "interval", "currency"],
                "domain": "stripe",
            },
            {
                "id": "stripe_09",
                "prompt": "How does Stripe Radar work for fraud detection? What are Radar rules?",
                "expected_keywords": ["Radar", "fraud", "rule", "risk", "score"],
                "domain": "stripe",
            },
            {
                "id": "stripe_10",
                "prompt": "Explain Stripe's payment method lifecycle. What states can a PaymentMethod be in?",
                "expected_keywords": ["PaymentMethod", "attach", "detach", "customer", "type"],
                "domain": "stripe",
            },
        ]

    elif domain == "supabase":
        return [
            {
                "id": "supabase_01",
                "prompt": "How do I set up Row Level Security (RLS) policies in Supabase for a multi-tenant app?",
                "expected_keywords": ["RLS", "policy", "auth.uid", "CREATE POLICY", "tenant"],
                "domain": "supabase",
            },
            {
                "id": "supabase_02",
                "prompt": "Explain how Supabase Realtime subscriptions work. How do I listen to INSERT events on a table?",
                "expected_keywords": ["Realtime", "subscribe", "INSERT", "channel", "postgres_changes"],
                "domain": "supabase",
            },
            {
                "id": "supabase_03",
                "prompt": "How do I use Supabase Edge Functions? What runtime do they use and how do I deploy?",
                "expected_keywords": ["Edge Function", "Deno", "deploy", "supabase functions", "serve"],
                "domain": "supabase",
            },
            {
                "id": "supabase_04",
                "prompt": "How does Supabase Auth handle JWT tokens? What's the difference between access and refresh tokens?",
                "expected_keywords": ["JWT", "access_token", "refresh_token", "auth", "session"],
                "domain": "supabase",
            },
            {
                "id": "supabase_05",
                "prompt": "How do I use Supabase Storage with signed URLs? What are the bucket policies?",
                "expected_keywords": ["Storage", "bucket", "signed", "URL", "upload"],
                "domain": "supabase",
            },
            {
                "id": "supabase_06",
                "prompt": "Explain pgvector integration in Supabase. How do I store and query embeddings?",
                "expected_keywords": ["pgvector", "embedding", "vector", "similarity", "ivfflat"],
                "domain": "supabase",
            },
            {
                "id": "supabase_07",
                "prompt": "How do I perform a join query using the Supabase JavaScript client? Show a foreign key example.",
                "expected_keywords": ["select", "foreign", "join", "supabase", "from"],
                "domain": "supabase",
            },
            {
                "id": "supabase_08",
                "prompt": "What are Supabase Database Functions and how do I call them via RPC from the client?",
                "expected_keywords": ["rpc", "function", "plpgsql", "call", "invoke"],
                "domain": "supabase",
            },
            {
                "id": "supabase_09",
                "prompt": "How do I set up Supabase Auth with OAuth providers like Google and GitHub?",
                "expected_keywords": ["OAuth", "provider", "Google", "GitHub", "signInWith"],
                "domain": "supabase",
            },
            {
                "id": "supabase_10",
                "prompt": "Explain Supabase migrations workflow. How do I manage schema changes in production?",
                "expected_keywords": ["migration", "schema", "supabase db", "diff", "push"],
                "domain": "supabase",
            },
        ]

    elif domain == "orca":
        return [
            {
                "id": "orca_01",
                "prompt": "Explain how ORCA optimizer handles correlated subqueries. What transformation does it apply?",
                "expected_keywords": ["correlated", "subquery", "decorrelat", "apply", "transform"],
                "domain": "orca",
            },
            {
                "id": "orca_02",
                "prompt": "What is the DXL (Data eXchange Language) format used by ORCA? How does it represent query plans?",
                "expected_keywords": ["DXL", "XML", "plan", "query", "represent"],
                "domain": "orca",
            },
            {
                "id": "orca_03",
                "prompt": "How does ORCA's memo structure work for plan enumeration? What are groups and group expressions?",
                "expected_keywords": ["memo", "group", "expression", "enumerat", "plan"],
                "domain": "orca",
            },
            {
                "id": "orca_04",
                "prompt": "Explain ORCA's cost model. How does it estimate the cost of hash joins vs nested loop joins?",
                "expected_keywords": ["cost", "hash join", "nested loop", "estimat", "cardinality"],
                "domain": "orca",
            },
            {
                "id": "orca_05",
                "prompt": "How does ORCA handle partition pruning in Greenplum? What metadata does it use?",
                "expected_keywords": ["partition", "prun", "Greenplum", "metadata", "scan"],
                "domain": "orca",
            },
            {
                "id": "orca_06",
                "prompt": "What are ORCA's transformation rules? Give examples of exploration and implementation rules.",
                "expected_keywords": ["transform", "rule", "explor", "implement", "logical"],
                "domain": "orca",
            },
            {
                "id": "orca_07",
                "prompt": "How does ORCA's search strategy (optimization phases) work? What is the role of the scheduler?",
                "expected_keywords": ["search", "phase", "scheduler", "optim", "job"],
                "domain": "orca",
            },
            {
                "id": "orca_08",
                "prompt": "Explain how ORCA generates motion operators for distributed query execution in Greenplum.",
                "expected_keywords": ["motion", "distribut", "gather", "broadcast", "redistribute"],
                "domain": "orca",
            },
            {
                "id": "orca_09",
                "prompt": "What statistics does ORCA use for cardinality estimation? How does it handle column correlations?",
                "expected_keywords": ["statistic", "cardinality", "histogram", "correlat", "estimat"],
                "domain": "orca",
            },
            {
                "id": "orca_10",
                "prompt": "How do you debug ORCA's query planning? What tools and flags are available for plan analysis?",
                "expected_keywords": ["debug", "explain", "plan", "flag", "trace"],
                "domain": "orca",
            },
        ]

    else:
        print(f"Unknown domain: {domain}. Available: stripe, supabase, orca", file=sys.stderr)
        sys.exit(1)


# ── スコアリング ──────────────────────────────────────────────────────

def score_response(response_text: str, expected_keywords: list[str]) -> dict:
    """キーワードマッチングによるスコアリング。"""
    response_lower = response_text.lower()
    matches = []
    misses = []

    for keyword in expected_keywords:
        if keyword.lower() in response_lower:
            matches.append(keyword)
        else:
            misses.append(keyword)

    total = len(expected_keywords)
    matched = len(matches)
    score = matched / total if total > 0 else 0.0

    return {
        "score": score,
        "matched": matched,
        "total": total,
        "matches": matches,
        "misses": misses,
    }


# ── API呼び出し ──────────────────────────────────────────────────────

async def call_model(
    session: aiohttp.ClientSession,
    url: str,
    prompt: str,
    max_tokens: int = 512,
) -> tuple[str, float]:
    """モデルにプロンプトを送信し、レスポンスとレイテンシを返す。"""
    payload = {
        "model": "default",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": False,
    }

    t0 = time.perf_counter()
    try:
        async with session.post(
            f"{url}/v1/chat/completions",
            json=payload,
            timeout=aiohttp.ClientTimeout(total=120),
        ) as resp:
            if resp.status != 200:
                elapsed = (time.perf_counter() - t0) * 1000
                return f"[ERROR: HTTP {resp.status}]", elapsed

            data = await resp.json()
            elapsed = (time.perf_counter() - t0) * 1000
            content = data.get("choices", [{}])[0].get("message", {}).get("content", "")
            return content, elapsed

    except Exception as e:
        elapsed = (time.perf_counter() - t0) * 1000
        return f"[ERROR: {e}]", elapsed


# ── メイン処理 ────────────────────────────────────────────────────────

async def main():
    parser = argparse.ArgumentParser(
        description="Experiment B: Specialist vs Generalist 精度比較",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--domain", required=True, choices=["stripe", "supabase", "orca"],
                        help="Test domain")
    parser.add_argument("--specialist-url", default="http://localhost:8080",
                        help="Specialist model URL (default: http://localhost:8080)")
    parser.add_argument("--generalist-url", default="http://localhost:8081",
                        help="Generalist model URL (default: http://localhost:8081)")
    parser.add_argument("--testset", type=str, default=None,
                        help="Path to JSONL testset file (optional, generates if not provided)")
    parser.add_argument("--generate-only", action="store_true",
                        help="Only generate testset JSONL and exit")
    parser.add_argument("--max-tokens", type=int, default=512,
                        help="Max tokens per response (default: 512)")
    parser.add_argument("--output", type=str, default=None,
                        help="Output JSON path (default: auto-generated)")
    args = parser.parse_args()

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    # テストセット読み込みまたは生成
    if args.testset:
        testset = []
        with open(args.testset, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    testset.append(json.loads(line))
        print(f"Loaded {len(testset)} problems from {args.testset}", file=sys.stderr)
    else:
        testset = generate_testset(args.domain)
        print(f"Generated {len(testset)} problems for domain={args.domain}", file=sys.stderr)

    # --generate-only: JSONLを出力して終了
    if args.generate_only:
        output_jsonl = RESULTS_DIR / f"testset_{args.domain}.jsonl"
        with open(output_jsonl, "w", encoding="utf-8") as f:
            for problem in testset:
                f.write(json.dumps(problem, ensure_ascii=False) + "\n")
        print(f"Testset saved to: {output_jsonl}", file=sys.stderr)
        return

    # ヘルスチェック
    async with aiohttp.ClientSession() as session:
        for name, url in [("specialist", args.specialist_url), ("generalist", args.generalist_url)]:
            try:
                async with session.get(
                    f"{url}/v1/models",
                    timeout=aiohttp.ClientTimeout(total=5),
                ) as resp:
                    if resp.status != 200:
                        print(f"WARNING: {name} at {url} returned status {resp.status}", file=sys.stderr)
            except Exception as e:
                print(f"ERROR: {name} at {url} is not reachable: {e}", file=sys.stderr)
                print("Start both servers before running this experiment.", file=sys.stderr)
                sys.exit(1)

    # 実験実行
    results = []
    specialist_scores = []
    generalist_scores = []

    async with aiohttp.ClientSession() as session:
        for i, problem in enumerate(testset):
            print(f"  [{i+1}/{len(testset)}] {problem['id']}...", file=sys.stderr)

            # Specialist
            spec_response, spec_latency = await call_model(
                session, args.specialist_url, problem["prompt"], args.max_tokens
            )
            spec_score = score_response(spec_response, problem["expected_keywords"])

            # Generalist
            gen_response, gen_latency = await call_model(
                session, args.generalist_url, problem["prompt"], args.max_tokens
            )
            gen_score = score_response(gen_response, problem["expected_keywords"])

            specialist_scores.append(spec_score["score"])
            generalist_scores.append(gen_score["score"])

            result_entry = {
                "id": problem["id"],
                "prompt": problem["prompt"],
                "expected_keywords": problem["expected_keywords"],
                "specialist": {
                    "response": spec_response[:500],  # 長すぎる場合は切り詰め
                    "latency_ms": round(spec_latency, 2),
                    **spec_score,
                },
                "generalist": {
                    "response": gen_response[:500],
                    "latency_ms": round(gen_latency, 2),
                    **gen_score,
                },
            }
            results.append(result_entry)

            print(f"    Specialist: {spec_score['score']:.0%} ({spec_score['matched']}/{spec_score['total']}), "
                  f"Generalist: {gen_score['score']:.0%} ({gen_score['matched']}/{gen_score['total']})",
                  file=sys.stderr)

    # サマリー
    summary = {
        "domain": args.domain,
        "num_problems": len(testset),
        "specialist": {
            "avg_score": round(statistics.mean(specialist_scores), 4) if specialist_scores else 0,
            "stdev": round(statistics.stdev(specialist_scores), 4) if len(specialist_scores) > 1 else 0,
            "min_score": round(min(specialist_scores), 4) if specialist_scores else 0,
            "max_score": round(max(specialist_scores), 4) if specialist_scores else 0,
        },
        "generalist": {
            "avg_score": round(statistics.mean(generalist_scores), 4) if generalist_scores else 0,
            "stdev": round(statistics.stdev(generalist_scores), 4) if len(generalist_scores) > 1 else 0,
            "min_score": round(min(generalist_scores), 4) if generalist_scores else 0,
            "max_score": round(max(generalist_scores), 4) if generalist_scores else 0,
        },
        "specialist_win_rate": round(
            sum(1 for s, g in zip(specialist_scores, generalist_scores) if s > g) / len(testset), 4
        ) if testset else 0,
        "generalist_win_rate": round(
            sum(1 for s, g in zip(specialist_scores, generalist_scores) if g > s) / len(testset), 4
        ) if testset else 0,
        "tie_rate": round(
            sum(1 for s, g in zip(specialist_scores, generalist_scores) if s == g) / len(testset), 4
        ) if testset else 0,
    }

    # 出力
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    output_path = Path(args.output) if args.output else RESULTS_DIR / f"exp_b_specialist_{args.domain}_{timestamp}.json"

    output_data = {
        "experiment": "exp_b_specialist_accuracy",
        "timestamp": timestamp,
        "config": {
            "domain": args.domain,
            "specialist_url": args.specialist_url,
            "generalist_url": args.generalist_url,
            "max_tokens": args.max_tokens,
        },
        "summary": summary,
        "results": results,
    }

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output_data, f, indent=2, ensure_ascii=False)

    print(f"\nResults saved to: {output_path}", file=sys.stderr)
    print(f"\n{'='*50}", file=sys.stderr)
    print(f"Domain: {args.domain}", file=sys.stderr)
    print(f"Specialist avg: {summary['specialist']['avg_score']:.1%}", file=sys.stderr)
    print(f"Generalist avg: {summary['generalist']['avg_score']:.1%}", file=sys.stderr)
    print(f"Specialist win rate: {summary['specialist_win_rate']:.1%}", file=sys.stderr)
    print(f"{'='*50}", file=sys.stderr)

    print(json.dumps(output_data, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    asyncio.run(main())
