#!/usr/bin/env python3
"""Hayabusa backend benchmark: llama.cpp vs MLX — Fixed 512-token I/O.

Comparable to vllm-mlx paper Table 1 format.
Both backends serve Qwen3.5-9B 4-bit quantized on Apple Silicon.

Conditions:
  - Prompt length: ~512 tokens (fixed long prompt)
  - Output length: 512 tokens (max_tokens=512)
  - Temperature: 0 (deterministic)
  - Concurrency: 1, 2, 4, 8, 16

Metrics per concurrency level:
  - Aggregate throughput (tok/s across all concurrent requests)
  - Average latency (ms)
  - P95 latency (ms)
  - Memory usage (RSS MB)

Usage:
    # Start both servers:
    # .build/debug/Hayabusa models/Qwen3-8B-Q4_K_M.gguf --backend llama --slots 16 &
    # HAYABUSA_PORT=8081 .build/debug/Hayabusa mlx-community/Qwen3-8B-4bit --backend mlx --slots 16 &

    python scripts/bench_llama_vs_mlx.py
    python scripts/bench_llama_vs_mlx.py --samples 10
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import aiohttp

# ── Config ──────────────────────────────────────────────────────────

LLAMA_PORT = 8080
MLX_PORT = 8081
LLAMA_URL = f"http://localhost:{LLAMA_PORT}/v1/chat/completions"
MLX_URL = f"http://localhost:{MLX_PORT}/v1/chat/completions"
MODEL = "local"

MAX_TOKENS = 512
TEMPERATURE = 0
CONCURRENCIES = [1, 2, 4, 8, 16]

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_PATH = SCRIPT_DIR / "bench_llama_vs_mlx.json"

# ~512 token prompt: a detailed technical question that forces long context processing.
# This is a single fixed prompt used for all requests to eliminate prompt variance.
FIXED_PROMPT = (
    "You are a computer science professor giving a detailed lecture. "
    "Please provide a comprehensive explanation of the following topics, "
    "covering each one in depth with examples and technical details.\n\n"
    "Topic 1: Memory Management in Modern Operating Systems\n"
    "Explain virtual memory, page tables, TLB caches, demand paging, "
    "copy-on-write, memory-mapped files, and the role of the MMU. "
    "Discuss how modern OSes like Linux and macOS handle memory allocation, "
    "fragmentation, and swapping. Explain the difference between physical "
    "and virtual address spaces, how page faults are handled, and the "
    "performance implications of TLB misses. Cover NUMA architectures "
    "and their impact on memory access patterns in multi-socket systems.\n\n"
    "Topic 2: Distributed Consensus Algorithms\n"
    "Compare and contrast Paxos, Raft, and PBFT consensus algorithms. "
    "For each algorithm, explain the leader election process, log "
    "replication mechanism, safety guarantees, and liveness properties. "
    "Discuss the CAP theorem and how each algorithm makes trade-offs "
    "between consistency, availability, and partition tolerance. "
    "Provide examples of real-world systems that use each algorithm, "
    "such as Google Chubby, etcd, and Hyperledger Fabric. Explain "
    "the concept of Byzantine fault tolerance and when it is necessary.\n\n"
    "Topic 3: GPU Architecture and Parallel Computing\n"
    "Describe the architecture of modern GPUs, including streaming "
    "multiprocessors, warp schedulers, shared memory, L1/L2 caches, "
    "and global memory. Explain the CUDA programming model, including "
    "thread blocks, grids, and warps. Discuss memory coalescing, bank "
    "conflicts, occupancy optimization, and the impact of branch "
    "divergence on performance. Compare NVIDIA's CUDA with Apple's "
    "Metal compute shaders and AMD's ROCm. Explain how tensor cores "
    "work and their role in accelerating matrix multiplication for "
    "deep learning workloads. Discuss the unified memory architecture "
    "of Apple Silicon and its advantages for machine learning inference."
)


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
    memory_rss_mb: float = 0.0

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
        """Aggregate throughput: total completion tokens / wall clock time."""
        return self.total_completion_tokens / self.wall_time_sec if self.wall_time_sec > 0 else 0

    @property
    def prompt_tok_per_sec(self) -> float:
        """Prompt processing throughput."""
        return self.total_prompt_tokens / self.wall_time_sec if self.wall_time_sec > 0 else 0

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


# ── Memory measurement ─────────────────────────────────────────────

def get_process_rss_mb(port: int) -> float:
    """Get RSS of the Hayabusa process listening on the given port."""
    try:
        # Find PID listening on port
        result = subprocess.run(
            ["lsof", "-ti", f"tcp:{port}", "-sTCP:LISTEN"],
            capture_output=True, text=True, timeout=5
        )
        pids = result.stdout.strip().split("\n")
        if not pids or not pids[0]:
            return 0.0
        pid = pids[0].strip()
        # Get RSS via ps (in KB on macOS)
        result = subprocess.run(
            ["ps", "-o", "rss=", "-p", pid],
            capture_output=True, text=True, timeout=5
        )
        rss_kb = int(result.stdout.strip())
        return rss_kb / 1024.0
    except Exception:
        return 0.0


# ── API ─────────────────────────────────────────────────────────────

async def call_api(
    session: aiohttp.ClientSession,
    url: str,
    semaphore: asyncio.Semaphore,
) -> RequestResult:
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": "You are a helpful assistant. Provide detailed, thorough answers."},
            {"role": "user", "content": FIXED_PROMPT},
        ],
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE,
    }
    t0 = time.perf_counter()
    try:
        async with semaphore:
            async with session.post(
                url, json=payload,
                timeout=aiohttp.ClientTimeout(total=600),
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


async def warmup(session: aiohttp.ClientSession, url: str):
    """Warmup with a short request to load model weights into cache."""
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": "Say OK."}],
        "max_tokens": 4,
        "temperature": 0,
    }
    try:
        async with session.post(url, json=payload,
                                timeout=aiohttp.ClientTimeout(total=120)) as resp:
            await resp.read()
    except Exception:
        pass


async def check_server(url: str) -> bool:
    async with aiohttp.ClientSession() as session:
        try:
            payload = {
                "model": MODEL,
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
    url: str, target_name: str, port: int,
    concurrency: int, num_samples: int,
) -> BenchResult:
    semaphore = asyncio.Semaphore(concurrency)

    async with aiohttp.ClientSession() as session:
        sys.stderr.write(f"  Warming up {target_name}... ")
        sys.stderr.flush()
        await warmup(session, url)
        sys.stderr.write("done\n")

        # Measure memory before
        mem_before = get_process_rss_mb(port)

        sys.stderr.write(f"  Running {num_samples} reqs (concurrency={concurrency}, "
                         f"prompt~512tok, output=512tok)...\n")

        t0 = time.perf_counter()
        tasks = [call_api(session, url, semaphore) for _ in range(num_samples)]
        results = await asyncio.gather(*tasks)
        wall_time = time.perf_counter() - t0

        # Measure memory after
        mem_after = get_process_rss_mb(port)

    bench = BenchResult(
        target=target_name, concurrency=concurrency,
        total_requests=num_samples,
        successful=sum(1 for r in results if r.success),
        failed=sum(1 for r in results if not r.success),
        wall_time_sec=wall_time,
        memory_rss_mb=max(mem_before, mem_after),
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


# ── Display (vllm-mlx Table 1 style) ──────────────────────────────

def print_table(results: list[BenchResult]):
    """Print results in box-drawing table format similar to vllm-mlx Table 1."""
    by_target: dict[str, dict[int, BenchResult]] = {}
    for r in results:
        by_target.setdefault(r.target, {})[r.concurrency] = r

    llama = by_target.get("llama.cpp", {})
    mlx = by_target.get("MLX", {})

    # ── Throughput Table ──
    print()
    print("  Model: Qwen3-8B 4-bit | Prompt: 512 tok | Output: 512 tok")
    print()
    print("  ┌──────┬─────────────────────────┬─────────────────────────┬────────┐")
    print("  │ Conc │       llama.cpp          │          MLX            │  倍率  │")
    print("  │      │  tok/s   Avg(ms)  P95(ms)│  tok/s   Avg(ms)  P95(ms)│MLX/llama│")
    print("  ├──────┼─────────────────────────┼─────────────────────────┼────────┤")

    for c in CONCURRENCIES:
        ll = llama.get(c)
        mx = mlx.get(c)
        if not ll or not mx:
            continue
        ratio = mx.tok_per_sec / ll.tok_per_sec if ll.tok_per_sec > 0 else 0
        print(f"  │ {c:>4} │ {ll.tok_per_sec:>6.1f}  {ll.avg_latency:>8.0f}  {ll.p95:>7.0f} │"
              f" {mx.tok_per_sec:>6.1f}  {mx.avg_latency:>8.0f}  {mx.p95:>7.0f} │ {ratio:>5.2f}x │")

    print("  └──────┴─────────────────────────┴─────────────────────────┴────────┘")

    # ── Memory ──
    ll_mem = max((r.memory_rss_mb for r in llama.values()), default=0)
    mx_mem = max((r.memory_rss_mb for r in mlx.values()), default=0)
    if ll_mem > 0 or mx_mem > 0:
        print()
        print(f"  Memory (peak RSS): llama.cpp = {ll_mem:,.0f} MB | MLX = {mx_mem:,.0f} MB")

    # ── Detailed raw table ──
    print()
    hdr = (f"  {'Backend':<10} {'Conc':>4} {'OK':>3}/{' Req':<3} "
           f"{'tok/s':>7} {'req/s':>6} {'Avg(ms)':>8} {'P50(ms)':>8} {'P95(ms)':>8} "
           f"{'P99(ms)':>8} {'CompTok':>7} {'Wall(s)':>7} {'RSS(MB)':>7}")
    print(hdr)
    print("  " + "─" * (len(hdr) - 2))
    for r in results:
        print(f"  {r.target:<10} {r.concurrency:>4} {r.successful:>3}/{r.total_requests:<3} "
              f"{r.tok_per_sec:>7.1f} {r.req_per_sec:>6.2f} {r.avg_latency:>8.0f} {r.p50:>8.0f} "
              f"{r.p95:>8.0f} {r.p99:>8.0f} {r.total_completion_tokens:>7} "
              f"{r.wall_time_sec:>7.1f} {r.memory_rss_mb:>7.0f}")
    print()


def save_results(results: list[BenchResult]):
    by_target: dict[str, dict[int, BenchResult]] = {}
    for r in results:
        by_target.setdefault(r.target, {})[r.concurrency] = r

    data = []
    for r in results:
        data.append({
            "backend": r.target,
            "concurrency": r.concurrency,
            "total_requests": r.total_requests,
            "successful": r.successful,
            "failed": r.failed,
            "wall_time_sec": round(r.wall_time_sec, 3),
            "aggregate_tok_per_sec": round(r.tok_per_sec, 2),
            "avg_latency_ms": round(r.avg_latency, 1),
            "p50_ms": round(r.p50, 1),
            "p95_ms": round(r.p95, 1),
            "p99_ms": round(r.p99, 1),
            "req_per_sec": round(r.req_per_sec, 3),
            "total_prompt_tokens": r.total_prompt_tokens,
            "total_completion_tokens": r.total_completion_tokens,
            "memory_rss_mb": round(r.memory_rss_mb, 1),
        })

    # Build comparison summary (vllm-mlx Table 1 style)
    llama = by_target.get("llama.cpp", {})
    mlx = by_target.get("MLX", {})
    comparison = []
    for c in CONCURRENCIES:
        ll = llama.get(c)
        mx = mlx.get(c)
        if ll and mx:
            ratio = mx.tok_per_sec / ll.tok_per_sec if ll.tok_per_sec > 0 else 0
            comparison.append({
                "concurrency": c,
                "llama_tok_per_sec": round(ll.tok_per_sec, 2),
                "mlx_tok_per_sec": round(mx.tok_per_sec, 2),
                "speedup_mlx_over_llama": round(ratio, 3),
                "llama_avg_latency_ms": round(ll.avg_latency, 1),
                "mlx_avg_latency_ms": round(mx.avg_latency, 1),
                "llama_p95_ms": round(ll.p95, 1),
                "mlx_p95_ms": round(mx.p95, 1),
            })

    out = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "config": {
            "model": "Qwen3-8B 4-bit",
            "llama_model_file": "Qwen3-8B-Q4_K_M.gguf",
            "mlx_model_id": "mlx-community/Qwen3-8B-4bit",
            "prompt_tokens": "~512 (fixed)",
            "max_output_tokens": MAX_TOKENS,
            "temperature": TEMPERATURE,
            "concurrencies": CONCURRENCIES,
        },
        "comparison": comparison,
        "raw_results": data,
    }

    with open(OUTPUT_PATH, "w") as f:
        json.dump(out, f, indent=2)
    print(f"  Results saved to {OUTPUT_PATH}")


# ── Main ────────────────────────────────────────────────────────────

async def main_async(args):
    num_samples = args.samples

    targets = [
        ("llama.cpp", LLAMA_URL, args.llama_port),
        ("MLX", MLX_URL, args.mlx_port),
    ]

    # Availability check
    available = []
    for name, url, port in targets:
        sys.stderr.write(f"Checking {name} at {url}... ")
        sys.stderr.flush()
        ok = await check_server(url)
        if ok:
            sys.stderr.write("OK\n")
            available.append((name, url, port))
        else:
            sys.stderr.write("UNAVAILABLE\n")

    if len(available) < 2:
        missing = [n for n, _, _ in targets if n not in {a[0] for a in available}]
        print(f"\nERROR: {', '.join(missing)} not available.")
        print()
        print("Start both servers:")
        print("  .build/debug/Hayabusa models/Qwen3-8B-Q4_K_M.gguf --backend llama --slots 16 &")
        print("  HAYABUSA_PORT=8081 .build/debug/Hayabusa mlx-community/Qwen3-8B-4bit --backend mlx --slots 16 &")
        sys.exit(1)

    print()
    print("  ╔══════════════════════════════════════════════════════════════════╗")
    print("  ║  Hayabusa Benchmark: llama.cpp vs MLX                           ║")
    print("  ║  Model: Qwen3-8B 4-bit quantized                                ║")
    print(f"  ║  Prompt: ~512 tok | Output: {MAX_TOKENS} tok | Temp: {TEMPERATURE}                  ║")
    print(f"  ║  Samples/level: {num_samples} | Concurrency: {CONCURRENCIES}       ║")
    print("  ╚══════════════════════════════════════════════════════════════════╝")
    print()

    all_results: list[BenchResult] = []

    for conc in CONCURRENCIES:
        for name, url, port in available:
            print(f"  ── {name} (concurrency={conc}) ──")
            result = await run_bench(url, name, port, conc, num_samples)
            all_results.append(result)
            print(f"     tok/s={result.tok_per_sec:.1f}  avg={result.avg_latency:.0f}ms  "
                  f"p95={result.p95:.0f}ms  "
                  f"({result.successful}/{result.total_requests} ok, "
                  f"{result.total_completion_tokens} comp tok)")
            print()

    print_table(all_results)
    save_results(all_results)


def main():
    parser = argparse.ArgumentParser(
        description="Hayabusa benchmark: llama.cpp vs MLX (512-token fixed I/O)")
    parser.add_argument("--samples", type=int, default=10,
                        help="Requests per concurrency level (default: 10)")
    parser.add_argument("--llama-port", type=int, default=8080,
                        help="Hayabusa llama.cpp port (default: 8080)")
    parser.add_argument("--mlx-port", type=int, default=8081,
                        help="Hayabusa MLX port (default: 8081)")
    args = parser.parse_args()

    global LLAMA_URL, MLX_URL
    LLAMA_URL = f"http://localhost:{args.llama_port}/v1/chat/completions"
    MLX_URL = f"http://localhost:{args.mlx_port}/v1/chat/completions"

    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
