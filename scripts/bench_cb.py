#!/usr/bin/env python3
"""Continuous Batching benchmark: Hayabusa (CB) vs Ollama 9B.

Runs the same benchmark as bench_9b_vs_9b.py but saves to bench_results_cb.json
and prints a comparison table against pre-CB results.

Usage:
    python bench_cb.py --samples 20
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
HAYABUSA_MODEL = "local"

OLLAMA_URL = "http://localhost:11434/v1/chat/completions"
OLLAMA_MODEL = "qwen3.5:9b"

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
OUTPUT_PATH = SCRIPT_DIR / "bench_results_cb.json"
PRE_CB_PATH = SCRIPT_DIR / "bench_results_9b_vs_9b.json"


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
                timeout=aiohttp.ClientTimeout(total=180),
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
                timeout=aiohttp.ClientTimeout(total=60),
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
    hdr = (f"{'Target':<12} {'Conc':>4} {'OK':>4} {'Fail':>4} "
           f"{'Avg(ms)':>8} {'P50(ms)':>8} {'P95(ms)':>8} {'P99(ms)':>8} "
           f"{'tok/s':>7} {'req/s':>6}")
    print(hdr)
    print("-" * len(hdr))

    for r in results:
        print(f"{r.target:<12} {r.concurrency:>4} {r.successful:>4} {r.failed:>4} "
              f"{r.avg_latency:>8.0f} {r.p50:>8.0f} {r.p95:>8.0f} {r.p99:>8.0f} "
              f"{r.tok_per_sec:>7.1f} {r.req_per_sec:>6.2f}")

    print("-" * len(hdr))


def print_cb_comparison(cb_results: list[BenchResult]):
    """Compare CB results against pre-CB results from bench_results_9b_vs_9b.json."""
    # Load pre-CB data
    pre_cb: dict[str, dict[int, dict]] = {}
    if PRE_CB_PATH.exists():
        with open(PRE_CB_PATH) as f:
            data = json.load(f)
        for r in data["results"]:
            pre_cb.setdefault(r["target"], {})[r["concurrency"]] = r

    # Organize CB results
    cb: dict[str, dict[int, BenchResult]] = {}
    for r in cb_results:
        cb.setdefault(r.target, {})[r.concurrency] = r

    h_cb = cb.get("hayabusa", {})
    h_pre = pre_cb.get("hayabusa", {})
    o_cb = cb.get("ollama", {})

    # --- Table 1: CB results (Hayabusa vs Ollama) ---
    print()
    print("=" * 100)
    print("  Continuous Batching Benchmark: Hayabusa (CB) vs Ollama (qwen3.5:9b)")
    print("=" * 100)

    print()
    print("  Conc   Hay tok/s  Oll tok/s  倍率     Hay req/s  Oll req/s  Hay Avg(ms)  Oll Avg(ms)  Hay P95")
    print("  " + "-" * 92)

    for c in CONCURRENCIES:
        h = h_cb.get(c)
        o = o_cb.get(c)
        if not h or not o:
            continue
        tok_x = h.tok_per_sec / o.tok_per_sec if o.tok_per_sec > 0 else 0
        print(f"  {c:>4}   {h.tok_per_sec:>9.1f}  {o.tok_per_sec:>9.1f}  {tok_x:>5.2f}x"
              f"   {h.req_per_sec:>9.2f}  {o.req_per_sec:>9.2f}"
              f"  {h.avg_latency:>11.0f}  {o.avg_latency:>11.0f}  {h.p95:>7.0f}")

    # --- Table 2: CB vs pre-CB (Hayabusa only) ---
    if h_pre:
        print()
        print("=" * 100)
        print("  Continuous Batching 効果 (Hayabusa: before vs after)")
        print("=" * 100)

        print()
        print("  Conc   Pre-CB tok/s  CB tok/s  改善    Pre-CB req/s  CB req/s  改善    Pre-CB P95  CB P95   改善")
        print("  " + "-" * 98)

        for c in CONCURRENCIES:
            h_now = h_cb.get(c)
            h_old = h_pre.get(c)
            if not h_now or not h_old:
                continue

            old_tok = h_old["tok_per_sec"]
            new_tok = h_now.tok_per_sec
            tok_change = ((new_tok - old_tok) / old_tok * 100) if old_tok > 0 else 0

            old_req = h_old["req_per_sec"]
            new_req = h_now.req_per_sec
            req_change = ((new_req - old_req) / old_req * 100) if old_req > 0 else 0

            old_p95 = h_old["p95_ms"]
            new_p95 = h_now.p95
            p95_change = ((new_p95 - old_p95) / old_p95 * 100) if old_p95 > 0 else 0

            def fmt_pct(v):
                sign = "+" if v > 0 else ""
                return f"{sign}{v:.0f}%"

            print(f"  {c:>4}   {old_tok:>12.1f}  {new_tok:>8.1f}  {fmt_pct(tok_change):>5}"
                  f"   {old_req:>12.3f}  {new_req:>8.3f}  {fmt_pct(req_change):>5}"
                  f"   {old_p95:>10.0f}  {new_p95:>6.0f}  {fmt_pct(p95_change):>6}")

    # --- Table 3: Full comparison grid ---
    print()
    print("=" * 100)
    print("  Full Comparison: Pre-CB Hayabusa / CB Hayabusa / Ollama")
    print("=" * 100)
    print()
    print("  Conc  │ Pre-CB Hay tok/s │ CB Hay tok/s │ Ollama tok/s │ CB vs Pre-CB │ CB vs Ollama")
    print("  " + "─" * 86)

    for c in CONCURRENCIES:
        h_now = h_cb.get(c)
        o = o_cb.get(c)
        h_old = h_pre.get(c) if h_pre else None
        if not h_now or not o:
            continue

        old_tok = h_old["tok_per_sec"] if h_old else 0
        new_tok = h_now.tok_per_sec
        o_tok = o.tok_per_sec

        cb_vs_pre = f"{new_tok/old_tok:.2f}x" if old_tok > 0 else "N/A"
        cb_vs_oll = f"{new_tok/o_tok:.2f}x" if o_tok > 0 else "N/A"

        print(f"  {c:>4}  │ {old_tok:>16.1f} │ {new_tok:>12.1f} │ {o_tok:>12.1f} │ {cb_vs_pre:>12} │ {cb_vs_oll:>12}")

    print()


def save_results(cb_results: list[BenchResult]):
    # Load pre-CB for embedding in output
    pre_cb_data = None
    if PRE_CB_PATH.exists():
        with open(PRE_CB_PATH) as f:
            pre_cb_data = json.load(f)

    data = []
    for r in cb_results:
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
            "hayabusa_model": "Qwen3.5-9B-Q4_K_M.gguf",
            "ollama_model": OLLAMA_MODEL,
            "max_tokens": MAX_TOKENS,
            "temperature": TEMPERATURE,
            "prompts_count": len(PROMPTS),
            "continuous_batching": True,
        },
        "results": data,
    }

    if pre_cb_data:
        out["pre_cb_results"] = pre_cb_data["results"]

    with open(OUTPUT_PATH, "w") as f:
        json.dump(out, f, indent=2)
    print(f"Results saved to {OUTPUT_PATH}")


# ── Main ────────────────────────────────────────────────────────────

async def main_async(args):
    num_samples = args.samples
    concurrencies = CONCURRENCIES

    targets = [
        ("hayabusa", HAYABUSA_URL, HAYABUSA_MODEL),
        ("ollama", OLLAMA_URL, OLLAMA_MODEL),
    ]

    # Availability check
    available = []
    for name, url, model in targets:
        sys.stderr.write(f"Checking {name} ({model}) at {url}... ")
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
        sys.exit(1)

    print()
    print("=" * 100)
    print("  Hayabusa (Continuous Batching) vs Ollama — Qwen3.5-9B Q4_K_M")
    print(f"  max_tokens={MAX_TOKENS}  temperature={TEMPERATURE}  prompts={len(PROMPTS)}  samples={num_samples}")
    print("=" * 100)
    print()

    all_results: list[BenchResult] = []

    for conc in concurrencies:
        for name, url, model in available:
            print(f"--- {name} (concurrency={conc}) ---")
            result = await run_bench(url, model, name, conc, num_samples)
            all_results.append(result)
            print(f"  => avg={result.avg_latency:.0f}ms  p95={result.p95:.0f}ms  "
                  f"tok/s={result.tok_per_sec:.1f}  ({result.successful}/{result.total_requests} ok)")
            print()

    print_result_table(all_results)
    print_cb_comparison(all_results)
    save_results(all_results)


def main():
    parser = argparse.ArgumentParser(
        description="Hayabusa Continuous Batching benchmark vs Ollama")
    parser.add_argument("--samples", type=int, default=20,
                        help="Requests per concurrency level (default: 20)")
    args = parser.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
