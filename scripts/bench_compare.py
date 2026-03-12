#!/usr/bin/env python3
"""Hayabusa vs Ollama 推論性能比較ベンチマーク.

同一プロンプト群を両サーバーに投げ、レイテンシ・スループット・トークン速度を比較する。

Usage:
    # 両方比較（デフォルト）
    python bench_compare.py

    # Hayabusaのみ
    python bench_compare.py --target hayabusa

    # 並列数指定
    python bench_compare.py --concurrency 1 2 4

    # サンプル数
    python bench_compare.py --samples 50
"""

from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import aiohttp

# ── Config ──────────────────────────────────────────────────────────

HAYABUSA_URL = "http://localhost:8080/v1/chat/completions"
OLLAMA_URL = "http://localhost:11434/v1/chat/completions"

# 固定プロンプト群（短・中・長）
PROMPTS = [
    # Short prompts
    {"role": "user", "content": "What is 2+2?"},
    {"role": "user", "content": "Say hello in Japanese."},
    {"role": "user", "content": "What color is the sky?"},
    # Medium prompts
    {"role": "user", "content": "Explain the difference between a list and a tuple in Python in 2 sentences."},
    {"role": "user", "content": "Write a one-line Python function that reverses a string."},
    {"role": "user", "content": "What are the three pillars of object-oriented programming?"},
    # Longer prompts
    {"role": "user", "content": "Explain how a hash table works. Cover: the hash function, collision resolution, and time complexity for insert/lookup. Keep it under 100 words."},
    {"role": "user", "content": "Compare merge sort and quicksort. Discuss their time complexity, space usage, and stability. Answer in 3-4 sentences."},
    {"role": "user", "content": "What is the CAP theorem in distributed systems? Give a brief example for each of the three trade-offs."},
    {"role": "user", "content": "Describe how garbage collection works in Java. Mention generational GC, mark-and-sweep, and when a full GC is triggered."},
]


@dataclass
class RequestResult:
    latency_ms: float
    prompt_tokens: int
    completion_tokens: int
    success: bool
    error: str | None = None


@dataclass
class BenchResult:
    target: str
    concurrency: int
    total_requests: int
    successful: int
    failed: int
    latencies_ms: list[float] = field(default_factory=list)
    total_prompt_tokens: int = 0
    total_completion_tokens: int = 0
    wall_time_sec: float = 0.0

    @property
    def p50(self) -> float:
        return _percentile(self.latencies_ms, 50) if self.latencies_ms else 0

    @property
    def p95(self) -> float:
        return _percentile(self.latencies_ms, 95) if self.latencies_ms else 0

    @property
    def p99(self) -> float:
        return _percentile(self.latencies_ms, 99) if self.latencies_ms else 0

    @property
    def avg_latency(self) -> float:
        return statistics.mean(self.latencies_ms) if self.latencies_ms else 0

    @property
    def tok_per_sec(self) -> float:
        if self.wall_time_sec <= 0:
            return 0
        return self.total_completion_tokens / self.wall_time_sec

    @property
    def req_per_sec(self) -> float:
        if self.wall_time_sec <= 0:
            return 0
        return self.successful / self.wall_time_sec


def _percentile(data: list[float], pct: int) -> float:
    if not data:
        return 0
    sorted_data = sorted(data)
    idx = (len(sorted_data) - 1) * pct / 100
    lo = int(idx)
    hi = min(lo + 1, len(sorted_data) - 1)
    frac = idx - lo
    return sorted_data[lo] * (1 - frac) + sorted_data[hi] * frac


# ── API calls ───────────────────────────────────────────────────────

async def call_api(
    session: aiohttp.ClientSession,
    url: str,
    messages: list[dict],
    model: str,
    semaphore: asyncio.Semaphore,
) -> RequestResult:
    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": 128,
        "temperature": 0,
    }

    t0 = time.perf_counter()
    try:
        async with semaphore:
            async with session.post(
                url,
                json=payload,
                timeout=aiohttp.ClientTimeout(total=120),
            ) as resp:
                raw = await resp.read()
                data = json.loads(raw.decode("utf-8", errors="replace"), strict=False)
                elapsed = (time.perf_counter() - t0) * 1000

                usage = data.get("usage", {})
                return RequestResult(
                    latency_ms=elapsed,
                    prompt_tokens=usage.get("prompt_tokens", 0),
                    completion_tokens=usage.get("completion_tokens", 0),
                    success=True,
                )
    except Exception as e:
        elapsed = (time.perf_counter() - t0) * 1000
        return RequestResult(
            latency_ms=elapsed,
            prompt_tokens=0,
            completion_tokens=0,
            success=False,
            error=str(e),
        )


# ── Warmup ──────────────────────────────────────────────────────────

async def warmup(session: aiohttp.ClientSession, url: str, model: str):
    """1リクエスト送ってキャッシュ/JIT等をウォームアップ."""
    sem = asyncio.Semaphore(1)
    msgs = [{"role": "user", "content": "Hi"}]
    await call_api(session, url, msgs, model, sem)


# ── Bench runner ────────────────────────────────────────────────────

async def run_bench(
    url: str,
    model: str,
    target_name: str,
    concurrency: int,
    num_samples: int,
) -> BenchResult:
    # Build request list by cycling through PROMPTS
    requests = []
    for i in range(num_samples):
        p = PROMPTS[i % len(PROMPTS)]
        requests.append([{"role": "system", "content": "Answer briefly."}, p])

    semaphore = asyncio.Semaphore(concurrency)

    async with aiohttp.ClientSession() as session:
        # Warmup
        sys.stderr.write(f"  Warming up {target_name}... ")
        sys.stderr.flush()
        await warmup(session, url, model)
        sys.stderr.write("done\n")

        # Run benchmark
        sys.stderr.write(f"  Running {num_samples} requests (concurrency={concurrency})...\n")

        t0 = time.perf_counter()
        tasks = [
            call_api(session, url, msgs, model, semaphore)
            for msgs in requests
        ]
        results = await asyncio.gather(*tasks)
        wall_time = time.perf_counter() - t0

    bench = BenchResult(
        target=target_name,
        concurrency=concurrency,
        total_requests=num_samples,
        successful=sum(1 for r in results if r.success),
        failed=sum(1 for r in results if not r.success),
        wall_time_sec=wall_time,
    )

    for r in results:
        if r.success:
            bench.latencies_ms.append(r.latency_ms)
            bench.total_prompt_tokens += r.prompt_tokens
            bench.total_completion_tokens += r.completion_tokens

    # Print errors if any
    errors = [r for r in results if not r.success]
    if errors:
        for e in errors[:3]:
            sys.stderr.write(f"    ERROR: {e.error}\n")
        if len(errors) > 3:
            sys.stderr.write(f"    ... and {len(errors) - 3} more errors\n")

    return bench


# ── Display ─────────────────────────────────────────────────────────

def print_result_table(results: list[BenchResult]):
    """結果テーブルを表示."""
    print()
    print("=" * 90)
    print(f"{'Target':<12} {'Conc':>4} {'OK':>4} {'Fail':>4} "
          f"{'Avg(ms)':>8} {'P50(ms)':>8} {'P95(ms)':>8} {'P99(ms)':>8} "
          f"{'tok/s':>7} {'req/s':>6}")
    print("-" * 90)

    for r in results:
        print(f"{r.target:<12} {r.concurrency:>4} {r.successful:>4} {r.failed:>4} "
              f"{r.avg_latency:>8.0f} {r.p50:>8.0f} {r.p95:>8.0f} {r.p99:>8.0f} "
              f"{r.tok_per_sec:>7.1f} {r.req_per_sec:>6.2f}")

    print("=" * 90)


def print_comparison(results: list[BenchResult]):
    """Hayabusa vs Ollama 比較."""
    by_target: dict[str, dict[int, BenchResult]] = {}
    for r in results:
        by_target.setdefault(r.target, {})[r.concurrency] = r

    if "hayabusa" not in by_target or "ollama" not in by_target:
        return

    print()
    print("== Hayabusa vs Ollama 比較 ==")
    print()

    concurrencies = sorted(set(r.concurrency for r in results))
    for c in concurrencies:
        h = by_target["hayabusa"].get(c)
        o = by_target["ollama"].get(c)
        if not h or not o:
            continue

        speedup_latency = o.avg_latency / h.avg_latency if h.avg_latency > 0 else 0
        speedup_tok = h.tok_per_sec / o.tok_per_sec if o.tok_per_sec > 0 else 0

        print(f"  Concurrency={c}:")
        print(f"    Latency:  Hayabusa {h.avg_latency:.0f}ms vs Ollama {o.avg_latency:.0f}ms "
              f"({speedup_latency:.2f}x)")
        print(f"    tok/s:    Hayabusa {h.tok_per_sec:.1f} vs Ollama {o.tok_per_sec:.1f} "
              f"({speedup_tok:.2f}x)")
        print(f"    P95:      Hayabusa {h.p95:.0f}ms vs Ollama {o.p95:.0f}ms")
        print()


def save_results(results: list[BenchResult], path: Path):
    """結果をJSONで保存."""
    data = []
    for r in results:
        data.append({
            "target": r.target,
            "concurrency": r.concurrency,
            "total_requests": r.total_requests,
            "successful": r.successful,
            "failed": r.failed,
            "wall_time_sec": round(r.wall_time_sec, 3),
            "avg_latency_ms": round(r.avg_latency, 1),
            "p50_ms": round(r.p50, 1),
            "p95_ms": round(r.p95, 1),
            "p99_ms": round(r.p99, 1),
            "tok_per_sec": round(r.tok_per_sec, 2),
            "req_per_sec": round(r.req_per_sec, 3),
            "total_prompt_tokens": r.total_prompt_tokens,
            "total_completion_tokens": r.total_completion_tokens,
        })

    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump({"timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"), "results": data}, f, indent=2)
    print(f"\nResults saved to {path}")


# ── Check server availability ───────────────────────────────────────

async def check_server(url: str, name: str) -> bool:
    """ヘルスチェック."""
    base = url.rsplit("/v1", 1)[0]
    health_urls = [f"{base}/health", f"{base}/api/tags"]

    async with aiohttp.ClientSession() as session:
        for health_url in health_urls:
            try:
                async with session.get(
                    health_url,
                    timeout=aiohttp.ClientTimeout(total=5),
                ) as resp:
                    if resp.status == 200:
                        return True
            except Exception:
                continue

        # Try the chat endpoint directly with a tiny request
        try:
            payload = {
                "model": "qwen3.5:4b" if "11434" in url else "local",
                "messages": [{"role": "user", "content": "hi"}],
                "max_tokens": 1,
                "temperature": 0,
            }
            async with session.post(
                url,
                json=payload,
                timeout=aiohttp.ClientTimeout(total=30),
            ) as resp:
                return resp.status == 200
        except Exception:
            return False


# ── Main ────────────────────────────────────────────────────────────

async def main_async(args):
    targets = args.target
    concurrencies = args.concurrency
    num_samples = args.samples

    configs = []
    if "hayabusa" in targets:
        configs.append(("hayabusa", HAYABUSA_URL, "local"))
    if "ollama" in targets:
        configs.append(("ollama", OLLAMA_URL, "qwen3.5:4b"))

    # Check server availability
    available = []
    for name, url, model in configs:
        sys.stderr.write(f"Checking {name} at {url}... ")
        ok = await check_server(url, name)
        if ok:
            sys.stderr.write("OK\n")
            available.append((name, url, model))
        else:
            sys.stderr.write("UNAVAILABLE (skipping)\n")

    if not available:
        print("No servers available. Start Hayabusa and/or Ollama first.")
        sys.exit(1)

    print(f"\nBenchmark: {num_samples} samples x concurrency {concurrencies}")
    print(f"Targets: {', '.join(name for name, _, _ in available)}")
    print()

    all_results: list[BenchResult] = []

    for conc in concurrencies:
        for name, url, model in available:
            print(f"--- {name} (concurrency={conc}) ---")
            result = await run_bench(url, model, name, conc, num_samples)
            all_results.append(result)
            print(f"  => avg={result.avg_latency:.0f}ms p95={result.p95:.0f}ms "
                  f"tok/s={result.tok_per_sec:.1f} ({result.successful}/{result.total_requests} ok)")
            print()

    print_result_table(all_results)
    print_comparison(all_results)

    out_path = Path(__file__).resolve().parent / "bench_results.json"
    save_results(all_results, out_path)


def main():
    parser = argparse.ArgumentParser(description="Hayabusa vs Ollama benchmark")
    parser.add_argument(
        "--target", nargs="+", default=["hayabusa", "ollama"],
        choices=["hayabusa", "ollama"],
        help="Targets to benchmark (default: both)",
    )
    parser.add_argument(
        "--concurrency", nargs="+", type=int, default=[1, 2, 4],
        help="Concurrency levels to test (default: 1 2 4)",
    )
    parser.add_argument(
        "--samples", type=int, default=30,
        help="Number of requests per concurrency level (default: 30)",
    )
    args = parser.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
