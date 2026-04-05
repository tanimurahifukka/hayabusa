#!/usr/bin/env python3
"""Experiment A: Uzu Cluster vs Single Server ベンチマーク.

Uzu分散推論クラスタとシングルサーバーの性能を比較する。
並行リクエスト数を段階的に増やし、レイテンシ・スループット・メモリを計測。

Usage:
    python scripts/paper/exp_a_uzu_cluster.py
    python scripts/paper/exp_a_uzu_cluster.py --concurrencies 1 4 8 16 32 64
    python scripts/paper/exp_a_uzu_cluster.py --single-url http://localhost:8080 --cluster-url http://localhost:8081
    python scripts/paper/exp_a_uzu_cluster.py --requests 200 --warmup 20
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
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

# ── 固定プロンプト（512トークン相当の入力） ───────────────────────────
# 長めのシステムプロンプト + ユーザープロンプトで512トークン近辺を確保
SYSTEM_PROMPT = (
    "You are a highly knowledgeable computer science professor specializing in "
    "distributed systems, operating systems, and computer architecture. You always "
    "provide detailed, accurate, and well-structured explanations with concrete "
    "examples. When explaining algorithms, you include time and space complexity "
    "analysis. You cite relevant papers and industry practices when appropriate. "
    "Your explanations are suitable for graduate-level students who already have "
    "a solid foundation in computer science fundamentals."
)

PROMPTS = [
    "Explain the Raft consensus algorithm in detail. Cover leader election, log replication, "
    "and safety guarantees. How does it compare to Paxos in terms of understandability and "
    "practical implementation? Discuss the role of term numbers and how split-brain scenarios "
    "are prevented. Include a concrete example of a 5-node cluster handling a network partition.",

    "Describe how modern CPUs implement out-of-order execution. Cover the reorder buffer, "
    "reservation stations, register renaming, and the commit stage. Explain Tomasulo's algorithm "
    "and how it handles WAR, WAW, and RAW hazards. Discuss the performance implications of "
    "speculative execution and its relationship to branch prediction accuracy.",

    "Explain the design of a lock-free concurrent queue using compare-and-swap operations. "
    "Cover the Michael-Scott queue algorithm, ABA problem and its solutions, memory reclamation "
    "strategies including hazard pointers and epoch-based reclamation. Discuss the performance "
    "characteristics compared to mutex-based queues under high contention scenarios.",

    "Describe the architecture of Google's Spanner database. Cover TrueTime API, external "
    "consistency, Paxos groups, directory placement, and the commit protocol for distributed "
    "transactions. Explain how GPS and atomic clocks are used to bound clock uncertainty. "
    "Compare with CockroachDB's approach to achieving similar guarantees without specialized hardware.",

    "Explain how the Linux kernel's Completely Fair Scheduler works. Cover the red-black tree "
    "data structure used for task ordering, virtual runtime calculation, nice values and their "
    "mapping to weights, group scheduling with cgroups, and the O(1) scheduling algorithm that "
    "CFS replaced. Discuss real-time scheduling classes (SCHED_FIFO, SCHED_RR) and their priority.",
]


# ── データクラス ──────────────────────────────────────────────────────

@dataclass
class RequestResult:
    latency_ms: float
    ttft_ms: float
    completion_tokens: int
    success: bool
    error: str | None = None


@dataclass
class ConditionResult:
    target: str  # "single" or "cluster"
    concurrency: int
    total_requests: int
    successful: int
    failed: int
    latencies_ms: list[float] = field(default_factory=list)
    ttfts_ms: list[float] = field(default_factory=list)
    total_completion_tokens: int = 0
    wall_time_sec: float = 0.0
    memory_rss_mb: float = 0.0

    @property
    def avg_latency(self) -> float:
        return statistics.mean(self.latencies_ms) if self.latencies_ms else 0

    @property
    def p50(self) -> float:
        return _pct(self.latencies_ms, 50)

    @property
    def p95(self) -> float:
        return _pct(self.latencies_ms, 95)

    @property
    def p99(self) -> float:
        return _pct(self.latencies_ms, 99)

    @property
    def tok_per_sec(self) -> float:
        return self.total_completion_tokens / self.wall_time_sec if self.wall_time_sec > 0 else 0

    @property
    def req_per_sec(self) -> float:
        return self.successful / self.wall_time_sec if self.wall_time_sec > 0 else 0

    def to_dict(self) -> dict:
        return {
            "target": self.target,
            "concurrency": self.concurrency,
            "total_requests": self.total_requests,
            "successful": self.successful,
            "failed": self.failed,
            "avg_latency_ms": round(self.avg_latency, 2),
            "p50_latency_ms": round(self.p50, 2),
            "p95_latency_ms": round(self.p95, 2),
            "p99_latency_ms": round(self.p99, 2),
            "throughput_tok_s": round(self.tok_per_sec, 2),
            "req_per_sec": round(self.req_per_sec, 2),
            "memory_rss_mb": round(self.memory_rss_mb, 2),
            "wall_time_sec": round(self.wall_time_sec, 2),
        }


def _pct(data: list[float], pct: int) -> float:
    if not data:
        return 0
    s = sorted(data)
    idx = (len(s) - 1) * pct / 100
    lo = int(idx)
    hi = min(lo + 1, len(s) - 1)
    frac = idx - lo
    return s[lo] * (1 - frac) + s[hi] * frac


def get_memory_rss_mb() -> float:
    """現在のプロセスのRSS（MB）を取得。os モジュールのみ使用。"""
    try:
        # macOS / Linux: /proc/self/statm or resource module
        import resource
        usage = resource.getrusage(resource.RUSAGE_SELF)
        # ru_maxrss はmacOS ではバイト、Linuxではキロバイト
        if sys.platform == "darwin":
            return usage.ru_maxrss / (1024 * 1024)
        else:
            return usage.ru_maxrss / 1024
    except Exception:
        return 0.0


# ── HTTP リクエスト ───────────────────────────────────────────────────

async def call_streaming(
    session: aiohttp.ClientSession,
    url: str,
    prompt: str,
    max_tokens: int,
    semaphore: asyncio.Semaphore,
) -> RequestResult:
    """ストリーミングAPIを呼び出し、TTFT・レイテンシを計測。"""
    payload = {
        "model": "default",
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
    }

    t0 = time.perf_counter()
    ttft = 0.0
    completion_tokens = 0
    first_token_seen = False

    try:
        async with semaphore:
            async with session.post(
                url, json=payload,
                timeout=aiohttp.ClientTimeout(total=300),
            ) as resp:
                if resp.status != 200:
                    elapsed = (time.perf_counter() - t0) * 1000
                    return RequestResult(elapsed, 0, 0, False, f"HTTP {resp.status}")

                async for line in resp.content:
                    text = line.decode("utf-8", errors="ignore").strip()
                    if not text or not text.startswith("data:"):
                        continue
                    data_str = text[5:].strip()
                    if data_str == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data_str)
                        if not first_token_seen:
                            choices = chunk.get("choices", [])
                            if choices and choices[0].get("delta", {}).get("content"):
                                ttft = (time.perf_counter() - t0) * 1000
                                first_token_seen = True
                        # トークン数を取得
                        usage = chunk.get("usage", {})
                        if usage.get("completion_tokens"):
                            completion_tokens = usage["completion_tokens"]
                        # delta からトークン数を推定
                        choices = chunk.get("choices", [])
                        if choices:
                            content = choices[0].get("delta", {}).get("content", "")
                            if content and completion_tokens == 0:
                                # 概算: 4文字 ≈ 1トークン
                                completion_tokens += max(1, len(content) // 4)
                    except json.JSONDecodeError:
                        continue

        elapsed = (time.perf_counter() - t0) * 1000
        return RequestResult(elapsed, ttft, completion_tokens, True)

    except Exception as e:
        elapsed = (time.perf_counter() - t0) * 1000
        return RequestResult(elapsed, 0, 0, False, str(e))


# ── ベンチマーク実行 ──────────────────────────────────────────────────

async def run_condition(
    url: str,
    target_name: str,
    concurrency: int,
    num_requests: int,
    warmup: int,
    max_tokens: int,
) -> ConditionResult:
    """1条件（target + concurrency）のベンチマークを実行。"""
    api_url = f"{url}/v1/chat/completions"
    sem = asyncio.Semaphore(concurrency)

    async with aiohttp.ClientSession() as session:
        # ウォームアップ
        if warmup > 0:
            print(f"  Warmup: {warmup} requests...", file=sys.stderr)
            warmup_tasks = [
                call_streaming(session, api_url, random.choice(PROMPTS), max_tokens, sem)
                for _ in range(warmup)
            ]
            await asyncio.gather(*warmup_tasks)

        # 本計測
        print(f"  Running: {num_requests} requests @ concurrency={concurrency}...", file=sys.stderr)
        prompts = [random.choice(PROMPTS) for _ in range(num_requests)]

        mem_before = get_memory_rss_mb()
        t_start = time.perf_counter()

        tasks = [
            call_streaming(session, api_url, p, max_tokens, sem)
            for p in prompts
        ]
        results = await asyncio.gather(*tasks)

        wall_time = time.perf_counter() - t_start
        mem_after = get_memory_rss_mb()

    # 集計
    condition = ConditionResult(
        target=target_name,
        concurrency=concurrency,
        total_requests=num_requests,
        successful=sum(1 for r in results if r.success),
        failed=sum(1 for r in results if not r.success),
        wall_time_sec=wall_time,
        memory_rss_mb=max(mem_before, mem_after),
    )

    for r in results:
        if r.success:
            condition.latencies_ms.append(r.latency_ms)
            condition.ttfts_ms.append(r.ttft_ms)
            condition.total_completion_tokens += r.completion_tokens

    return condition


async def health_check(url: str) -> bool:
    """サーバーが起動しているか確認。"""
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                f"{url}/health",
                timeout=aiohttp.ClientTimeout(total=5),
            ) as resp:
                return resp.status == 200
    except Exception:
        return False


async def main():
    parser = argparse.ArgumentParser(
        description="Experiment A: Uzu Cluster vs Single Server ベンチマーク",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--single-url", default="http://localhost:8080",
                        help="Single server URL (default: http://localhost:8080)")
    parser.add_argument("--cluster-url", default="http://localhost:8081",
                        help="Cluster server URL (default: http://localhost:8081)")
    parser.add_argument("--concurrencies", nargs="+", type=int, default=[1, 4, 8, 16, 32],
                        help="Concurrency levels to test (default: 1 4 8 16 32)")
    parser.add_argument("--requests", type=int, default=100,
                        help="Requests per condition (default: 100)")
    parser.add_argument("--warmup", type=int, default=10,
                        help="Warmup requests per condition (default: 10)")
    parser.add_argument("--max-tokens", type=int, default=128,
                        help="Max tokens per request (default: 128)")
    parser.add_argument("--single-only", action="store_true",
                        help="Only run single server benchmark")
    parser.add_argument("--cluster-only", action="store_true",
                        help="Only run cluster benchmark")
    parser.add_argument("--output", type=str, default=None,
                        help="Output JSON path (default: auto-generated with timestamp)")
    args = parser.parse_args()

    # 出力パス
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    output_path = Path(args.output) if args.output else RESULTS_DIR / f"exp_a_uzu_{timestamp}.json"

    # チェックポイント: 既存結果の読み込み
    existing_results: list[dict] = []
    completed_keys: set[str] = set()
    if output_path.exists():
        try:
            with open(output_path, "r") as f:
                data = json.load(f)
                existing_results = data.get("conditions", [])
                for r in existing_results:
                    completed_keys.add(f"{r['target']}_{r['concurrency']}")
            print(f"Checkpoint: {len(existing_results)} conditions already completed", file=sys.stderr)
        except (json.JSONDecodeError, KeyError):
            pass

    # ターゲット設定
    targets = []
    if not args.cluster_only:
        targets.append(("single", args.single_url))
    if not args.single_only:
        targets.append(("cluster", args.cluster_url))

    # ヘルスチェック
    for name, url in targets:
        alive = await health_check(url)
        if not alive:
            print(f"WARNING: {name} server at {url} is not responding.", file=sys.stderr)
            print(f"  Start the server first. Skipping {name}.", file=sys.stderr)
            targets = [(n, u) for n, u in targets if n != name]

    if not targets:
        print("ERROR: No servers available. Exiting.", file=sys.stderr)
        sys.exit(1)

    all_conditions = list(existing_results)

    for target_name, url in targets:
        print(f"\n{'='*60}", file=sys.stderr)
        print(f"Target: {target_name} ({url})", file=sys.stderr)
        print(f"{'='*60}", file=sys.stderr)

        for conc in args.concurrencies:
            key = f"{target_name}_{conc}"
            if key in completed_keys:
                print(f"  Skipping {target_name} @ concurrency={conc} (already completed)", file=sys.stderr)
                continue

            print(f"\n--- {target_name} @ concurrency={conc} ---", file=sys.stderr)
            result = await run_condition(
                url=url,
                target_name=target_name,
                concurrency=conc,
                num_requests=args.requests,
                warmup=args.warmup,
                max_tokens=args.max_tokens,
            )

            rd = result.to_dict()
            all_conditions.append(rd)

            print(f"  Result: {rd['successful']}/{rd['total_requests']} success, "
                  f"avg={rd['avg_latency_ms']:.0f}ms, p95={rd['p95_latency_ms']:.0f}ms, "
                  f"throughput={rd['throughput_tok_s']:.1f} tok/s, "
                  f"req/s={rd['req_per_sec']:.2f}", file=sys.stderr)

            # 中間保存
            output_data = {
                "experiment": "exp_a_uzu_cluster",
                "timestamp": timestamp,
                "config": {
                    "requests_per_condition": args.requests,
                    "warmup": args.warmup,
                    "max_tokens": args.max_tokens,
                    "concurrencies": args.concurrencies,
                },
                "conditions": all_conditions,
            }
            with open(output_path, "w", encoding="utf-8") as f:
                json.dump(output_data, f, indent=2, ensure_ascii=False)

    # 最終出力
    output_data = {
        "experiment": "exp_a_uzu_cluster",
        "timestamp": timestamp,
        "config": {
            "requests_per_condition": args.requests,
            "warmup": args.warmup,
            "max_tokens": args.max_tokens,
            "concurrencies": args.concurrencies,
        },
        "conditions": all_conditions,
    }
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output_data, f, indent=2, ensure_ascii=False)

    print(f"\nResults saved to: {output_path}", file=sys.stderr)
    print(json.dumps(output_data, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    asyncio.run(main())
