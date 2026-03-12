#!/usr/bin/env python3
"""Hayabusa backend benchmark: llama.cpp vs MLX.

Compares two Hayabusa instances running different backends on different ports.
- Hayabusa-Llama: port 8080 (default)
- Hayabusa-MLX:   port 8081

Usage:
    # Start both servers first:
    # .build/debug/Hayabusa models/Qwen3.5-9B-Q4_K_M.gguf --backend llama &
    # HAYABUSA_PORT=8081 .build/debug/Hayabusa mlx-community/Qwen2.5-7B-Instruct-4bit --backend mlx &

    python scripts/bench_mlx_vs_llama.py --samples 20
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

LLAMA_URL = "http://localhost:8080/v1/chat/completions"
LLAMA_MODEL = "local"

MLX_URL = "http://localhost:8081/v1/chat/completions"
MLX_MODEL = "local"

MAX_TOKENS = 128
TEMPERATURE = 0

CONCURRENCIES = [1, 2, 4, 8]

PROMPTS = [
    {"role": "user", "content": "What is 2+2?"},
    {"role": "user", "content": "Say hello in Japanese."},
    {"role": "user", "content": "What color is the sky?"},
    {"role": "user", "content": "Explain the difference between a list and a tuple in Python in 2 sentences."},
    {"role": "user", "content": "Write a one-line Python function that reverses a string."},
    {"role": "user", "content": "What are the three pillars of object-oriented programming?"},
    {"role": "user", "content": "Explain how a hash table works. Cover: the hash function, collision resolution, and time complexity for insert/lookup. Keep it under 100 words."},
    {"role": "user", "content": "Compare merge sort and quicksort. Discuss their time complexity, space usage, and stability. Answer in 3-4 sentences."},
    {"role": "user", "content": "What is the CAP theorem in distributed systems? Give a brief example for each of the three trade-offs."},
    {"role": "user", "content": "Describe how garbage collection works in Java. Mention generational GC, mark-and-sweep, and when a full GC is triggered."},
]

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_PATH = SCRIPT_DIR / "bench_results_mlx_vs_llama.json"


# ── Data classes ────────────────────────────────────────────────────

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
        return _pct(self.latencies_ms, 50)

    @property
    def p95(self) -> float:
        return _pct(self.latencies_ms, 95)

    @property
    def p99(self) -> float:
        return _pct(self.latencies_ms, 99)

    @property
    def avg_latency(self) -> float:
        return statistics.mean(self.latencies_ms) if self.latencies_ms else 0

    @property
    def tok_per_sec(self) -> float:
        return self.total_completion_tokens / self.wall_time_sec if self.wall_time_sec > 0 else 0

    @property
    def req_per_sec(self) -> float:
        return self.successful / self.wall_time_sec if self.wall_time_sec > 0 else 0


def _pct(data: list[float], pct: int) -> float:
    if not data:
        return 0
    s = sorted(data)
    idx = (len(s) - 1) * pct / 100
    lo = int(idx)
    hi = min(lo + 1, len(s) - 1)
    frac = idx - lo
    return s[lo] * (1 - frac) + s[hi] * frac


# ── API ─────────────────────────────────────────────────────────────

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
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE,
    }
    t0 = time.perf_counter()
    try:
        async with semaphore:
            async with session.post(
                url, json=payload,
                timeout=aiohttp.ClientTimeout(total=300),
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
        return RequestResult(latency_ms=elapsed, prompt_tokens=0,
                             completion_tokens=0, success=False, error=str(e))


async def warmup(session: aiohttp.ClientSession, url: str, model: str):
    sem = asyncio.Semaphore(1)
    await call_api(session, url,
                   [{"role": "user", "content": "Hi"}], model, sem)


async def check_server(url: str, model: str) -> bool:
    async with aiohttp.ClientSession() as session:
        try:
            payload = {
                "model": model,
                "messages": [{"role": "user", "content": "hi"}],
                "max_tokens": 1,
                "temperature": 0,
            }
            async with session.post(
                url, json=payload,
                timeout=aiohttp.ClientTimeout(total=120),
            ) as resp:
                return resp.status == 200
        except Exception:
            return False


# ── Runner ──────────────────────────────────────────────────────────

async def run_bench(
    url: str, model: str, target_name: str,
    concurrency: int, num_samples: int,
) -> BenchResult:
    requests = []
    for i in range(num_samples):
        p = PROMPTS[i % len(PROMPTS)]
        requests.append([{"role": "system", "content": "Answer briefly."}, p])

    semaphore = asyncio.Semaphore(concurrency)

    async with aiohttp.ClientSession() as session:
        sys.stderr.write(f"  Warming up {target_name}... ")
        sys.stderr.flush()
        await warmup(session, url, model)
        sys.stderr.write("done\n")
        sys.stderr.write(f"  Running {num_samples} reqs (concurrency={concurrency})...\n")

        t0 = time.perf_counter()
        tasks = [call_api(session, url, msgs, model, semaphore) for msgs in requests]
        results = await asyncio.gather(*tasks)
        wall_time = time.perf_counter() - t0

    bench = BenchResult(
        target=target_name, concurrency=concurrency,
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

    errors = [r for r in results if not r.success]
    if errors:
        for e in errors[:3]:
            sys.stderr.write(f"    ERROR: {e.error}\n")
        if len(errors) > 3:
            sys.stderr.write(f"    ... and {len(errors)-3} more errors\n")

    return bench


# ── Display ─────────────────────────────────────────────────────────

def print_result_table(results: list[BenchResult]):
    print()
    hdr = (f"{'Target':<16} {'Conc':>4} {'OK':>4} {'Fail':>4} "
           f"{'Avg(ms)':>8} {'P50(ms)':>8} {'P95(ms)':>8} {'P99(ms)':>8} "
           f"{'tok/s':>7} {'req/s':>6}")
    print(hdr)
    print("-" * len(hdr))

    for r in results:
        print(f"{r.target:<16} {r.concurrency:>4} {r.successful:>4} {r.failed:>4} "
              f"{r.avg_latency:>8.0f} {r.p50:>8.0f} {r.p95:>8.0f} {r.p99:>8.0f} "
              f"{r.tok_per_sec:>7.1f} {r.req_per_sec:>6.2f}")

    print("-" * len(hdr))


def print_comparison(results: list[BenchResult]):
    by_target: dict[str, dict[int, BenchResult]] = {}
    for r in results:
        by_target.setdefault(r.target, {})[r.concurrency] = r

    llama_data = by_target.get("hayabusa-llama", {})
    mlx_data = by_target.get("hayabusa-mlx", {})
    if not llama_data or not mlx_data:
        return

    print()
    print("=" * 100)
    print("  Backend Comparison: llama.cpp vs MLX (both via Hayabusa)")
    print("=" * 100)
    print()
    print("  Conc  │ Llama tok/s │ MLX tok/s │ 倍率   │ Llama Avg(ms) │ MLX Avg(ms) │ Llama P95 │ MLX P95")
    print("  " + "─" * 90)

    for c in CONCURRENCIES:
        ll = llama_data.get(c)
        mx = mlx_data.get(c)
        if not ll or not mx:
            continue
        tok_ratio = mx.tok_per_sec / ll.tok_per_sec if ll.tok_per_sec > 0 else 0
        print(f"  {c:>4}  │ {ll.tok_per_sec:>11.1f} │ {mx.tok_per_sec:>9.1f} │ {tok_ratio:>5.2f}x │"
              f" {ll.avg_latency:>13.0f} │ {mx.avg_latency:>11.0f} │ {ll.p95:>9.0f} │ {mx.p95:>7.0f}")

    print()


def save_results(results: list[BenchResult]):
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

    out = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "config": {
            "llama_model": "Qwen3.5-9B-Q4_K_M.gguf (llama.cpp)",
            "mlx_model": "Qwen2.5-7B-Instruct-4bit (MLX)",
            "max_tokens": MAX_TOKENS,
            "temperature": TEMPERATURE,
            "prompts_count": len(PROMPTS),
        },
        "results": data,
    }

    with open(OUTPUT_PATH, "w") as f:
        json.dump(out, f, indent=2)
    print(f"Results saved to {OUTPUT_PATH}")


# ── Main ────────────────────────────────────────────────────────────

async def main_async(args):
    num_samples = args.samples

    targets = [
        ("hayabusa-llama", LLAMA_URL, LLAMA_MODEL),
        ("hayabusa-mlx", MLX_URL, MLX_MODEL),
    ]

    # Availability check
    available = []
    for name, url, model in targets:
        sys.stderr.write(f"Checking {name} at {url}... ")
        sys.stderr.flush()
        ok = await check_server(url, model)
        if ok:
            sys.stderr.write("OK\n")
            available.append((name, url, model))
        else:
            sys.stderr.write("UNAVAILABLE\n")

    if len(available) < 2:
        missing = [n for n, _, _ in targets if n not in {a[0] for a in available}]
        print(f"\nERROR: {', '.join(missing)} not available.")
        print()
        print("Start both servers:")
        print("  .build/debug/Hayabusa models/Qwen3.5-9B-Q4_K_M.gguf --backend llama &")
        print("  HAYABUSA_PORT=8081 .build/debug/Hayabusa mlx-community/Qwen2.5-7B-Instruct-4bit --backend mlx &")
        sys.exit(1)

    print()
    print("=" * 100)
    print("  Hayabusa Backend Benchmark: llama.cpp vs MLX")
    print(f"  max_tokens={MAX_TOKENS}  temperature={TEMPERATURE}  prompts={len(PROMPTS)}  samples={num_samples}")
    print("=" * 100)
    print()

    all_results: list[BenchResult] = []

    for conc in CONCURRENCIES:
        for name, url, model in available:
            print(f"--- {name} (concurrency={conc}) ---")
            result = await run_bench(url, model, name, conc, num_samples)
            all_results.append(result)
            print(f"  => avg={result.avg_latency:.0f}ms  p95={result.p95:.0f}ms  "
                  f"tok/s={result.tok_per_sec:.1f}  ({result.successful}/{result.total_requests} ok)")
            print()

    print_result_table(all_results)
    print_comparison(all_results)
    save_results(all_results)


def main():
    parser = argparse.ArgumentParser(
        description="Hayabusa backend benchmark: llama.cpp vs MLX")
    parser.add_argument("--samples", type=int, default=20,
                        help="Requests per concurrency level (default: 20)")
    parser.add_argument("--llama-port", type=int, default=8080,
                        help="Hayabusa-Llama port (default: 8080)")
    parser.add_argument("--mlx-port", type=int, default=8081,
                        help="Hayabusa-MLX port (default: 8081)")
    args = parser.parse_args()

    global LLAMA_URL, MLX_URL
    LLAMA_URL = f"http://localhost:{args.llama_port}/v1/chat/completions"
    MLX_URL = f"http://localhost:{args.mlx_port}/v1/chat/completions"

    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
