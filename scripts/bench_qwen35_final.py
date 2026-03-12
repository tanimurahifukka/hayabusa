#!/usr/bin/env python3
"""Hayabusa Qwen3.5-9B Final Benchmark: llama.cpp vs MLX.

Fixed 512-token input / 512-token output, sweeping concurrency 1→20.
Measures aggregate tok/s, avg latency, P95, and RSS memory.
Outputs vllm-mlx paper Table 1 style.

Usage:
    # Servers are started automatically by this script.
    python scripts/bench_qwen35_final.py
"""

from __future__ import annotations

import asyncio
import json
import os
import signal
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import aiohttp

# ── Config ──────────────────────────────────────────────────────────

HAYABUSA_BIN = Path(__file__).resolve().parent.parent / ".build" / "debug" / "Hayabusa"
LLAMA_MODEL = "models/Qwen3.5-9B-Q4_K_M.gguf"
MLX_MODEL = "mlx-community/Qwen3.5-9B-MLX-4bit"

LLAMA_PORT = 8090
MLX_PORT = 8091

MAX_TOKENS = 512
TEMPERATURE = 0.0

CONCURRENCIES = [1, 2, 4, 8, 16, 20]
SAMPLES_PER_CONC = 20  # total requests per concurrency level

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_PATH = SCRIPT_DIR / "bench_qwen35_final.json"

# ── 512-token prompt ────────────────────────────────────────────────
# Approx 512 tokens: long passage for uniform prompt length.

LONG_PROMPT = (
    "You are a knowledgeable computer science professor. A student asks you to explain "
    "the following topics in detail. Provide thorough explanations with examples.\n\n"
    "Topic 1: Explain how a modern CPU executes instructions using pipelining. "
    "Cover the five classic pipeline stages: instruction fetch (IF), instruction decode (ID), "
    "execute (EX), memory access (MEM), and write-back (WB). Discuss pipeline hazards "
    "including data hazards, control hazards, and structural hazards. Explain how techniques "
    "like forwarding, branch prediction, and stalling help mitigate these hazards. "
    "Give a concrete example of a data hazard with two dependent instructions.\n\n"
    "Topic 2: Describe the memory hierarchy in modern computer systems. Start from "
    "CPU registers, then L1 cache, L2 cache, L3 cache, main memory (DRAM), and finally "
    "secondary storage (SSD/HDD). For each level, discuss typical size, latency, and "
    "bandwidth. Explain the principle of locality (temporal and spatial) and how it "
    "justifies the hierarchical design. Discuss cache replacement policies such as LRU, "
    "FIFO, and random replacement. Explain the difference between write-through and "
    "write-back cache policies.\n\n"
    "Topic 3: Explain the concept of virtual memory. Discuss page tables, TLBs "
    "(Translation Lookaside Buffers), page faults, and demand paging. Describe how "
    "the operating system manages the mapping between virtual addresses and physical "
    "addresses. Explain multi-level page tables and why they are needed for 64-bit "
    "address spaces. Discuss the role of the MMU (Memory Management Unit) in address "
    "translation. Cover swap space and how the OS decides which pages to evict using "
    "algorithms like LRU approximation and the clock algorithm.\n\n"
    "Topic 4: Describe how modern operating systems handle process scheduling. "
    "Explain the difference between preemptive and cooperative multitasking. Discuss "
    "scheduling algorithms including First-Come-First-Served (FCFS), Shortest Job First "
    "(SJF), Round Robin (RR), and Multilevel Feedback Queue (MLFQ). For each algorithm, "
    "analyze its advantages, disadvantages, and typical use cases. Explain how Linux's "
    "Completely Fair Scheduler (CFS) works using a red-black tree of virtual runtimes. "
    "Discuss the concepts of nice values, priority inversion, and priority inheritance.\n\n"
    "Please provide detailed explanations with concrete examples for each topic."
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
    def avg_latency(self) -> float:
        return statistics.mean(self.latencies_ms) if self.latencies_ms else 0

    @property
    def agg_tok_per_sec(self) -> float:
        return self.total_completion_tokens / self.wall_time_sec if self.wall_time_sec > 0 else 0


def _pct(data: list[float], pct: int) -> float:
    if not data:
        return 0
    s = sorted(data)
    idx = (len(s) - 1) * pct / 100
    lo = int(idx)
    hi = min(lo + 1, len(s) - 1)
    frac = idx - lo
    return s[lo] * (1 - frac) + s[hi] * frac


# ── Server management ──────────────────────────────────────────────

def get_rss_mb(pid: int) -> float:
    """Get RSS in MB for a process via ps."""
    try:
        out = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(pid)],
            text=True, timeout=5
        ).strip()
        return int(out) / 1024.0 if out else 0.0
    except Exception:
        return 0.0


def start_server(model: str, backend: str, port: int, slots: int = 4) -> subprocess.Popen:
    env = os.environ.copy()
    env["HAYABUSA_PORT"] = str(port)
    cmd = [str(HAYABUSA_BIN), model, "--backend", backend, "--slots", str(slots)]
    if backend == "llama":
        cmd += ["--ctx-per-slot", "4096"]
    # cwd must be project root so relative model paths work
    project_root = HAYABUSA_BIN.parent.parent.parent
    proc = subprocess.Popen(
        cmd, env=env,
        cwd=str(project_root),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True
    )
    return proc


async def wait_for_server(port: int, timeout: int = 300) -> bool:
    url = f"http://localhost:{port}/health"
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            async with aiohttp.ClientSession() as s:
                async with s.get(url, timeout=aiohttp.ClientTimeout(total=5)) as resp:
                    if resp.status == 200:
                        return True
        except Exception:
            pass
        await asyncio.sleep(1)
    return False


def kill_server(proc: subprocess.Popen):
    try:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=10)
    except Exception:
        proc.kill()
        proc.wait(timeout=5)


# ── API call ───────────────────────────────────────────────────────

async def call_api(
    session: aiohttp.ClientSession,
    url: str,
    messages: list[dict],
    semaphore: asyncio.Semaphore,
) -> RequestResult:
    payload = {
        "model": "local",
        "messages": messages,
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
        return RequestResult(
            latency_ms=elapsed, prompt_tokens=0,
            completion_tokens=0, success=False, error=str(e)
        )


# ── Benchmark runner ───────────────────────────────────────────────

async def run_bench(
    port: int, pid: int, target_name: str,
    concurrency: int, num_samples: int,
) -> BenchResult:
    url = f"http://localhost:{port}/v1/chat/completions"
    messages = [
        {"role": "system", "content": "You are a helpful assistant. Answer in detail."},
        {"role": "user", "content": LONG_PROMPT},
    ]

    semaphore = asyncio.Semaphore(concurrency)

    # Warmup
    async with aiohttp.ClientSession() as session:
        sys.stderr.write(f"  [{target_name}] warmup... ")
        sys.stderr.flush()
        warm_payload = {
            "model": "local",
            "messages": [{"role": "user", "content": "Say hi."}],
            "max_tokens": 8,
            "temperature": 0,
        }
        try:
            async with session.post(
                url, json=warm_payload,
                timeout=aiohttp.ClientTimeout(total=120),
            ) as resp:
                await resp.read()
        except Exception:
            pass
        sys.stderr.write("done\n")

    # Measure memory before
    mem_before = get_rss_mb(pid)

    # Run
    async with aiohttp.ClientSession() as session:
        sys.stderr.write(f"  [{target_name}] conc={concurrency}, {num_samples} reqs... ")
        sys.stderr.flush()

        requests = [messages] * num_samples

        t0 = time.perf_counter()
        tasks = [call_api(session, url, msgs, semaphore) for msgs in requests]
        results = await asyncio.gather(*tasks)
        wall_time = time.perf_counter() - t0

    # Measure memory after
    mem_after = get_rss_mb(pid)
    peak_mem = max(mem_before, mem_after)

    bench = BenchResult(
        target=target_name, concurrency=concurrency,
        total_requests=num_samples,
        successful=sum(1 for r in results if r.success),
        failed=sum(1 for r in results if not r.success),
        wall_time_sec=wall_time,
        memory_rss_mb=peak_mem,
    )
    for r in results:
        if r.success:
            bench.latencies_ms.append(r.latency_ms)
            bench.total_prompt_tokens += r.prompt_tokens
            bench.total_completion_tokens += r.completion_tokens

    errors = [r for r in results if not r.success]
    if errors:
        for e in errors[:3]:
            sys.stderr.write(f"\n    ERROR: {e.error}")
        if len(errors) > 3:
            sys.stderr.write(f"\n    ... and {len(errors) - 3} more errors")

    sys.stderr.write(
        f"tok/s={bench.agg_tok_per_sec:.1f}  "
        f"avg={bench.avg_latency:.0f}ms  "
        f"mem={peak_mem:.0f}MB\n"
    )
    return bench


# ── Display ────────────────────────────────────────────────────────

def print_table(llama_results: dict[int, BenchResult], mlx_results: dict[int, BenchResult]):
    print()
    print("=" * 110)
    print("  Hayabusa Qwen3.5-9B Benchmark — llama.cpp (GGUF Q4_K_M) vs MLX (4bit)")
    print(f"  Prompt ≈512 tok | Output = {MAX_TOKENS} tok | Samples = {SAMPLES_PER_CONC}/conc")
    print("=" * 110)

    # ── Aggregate throughput table (vllm-mlx Table 1 style) ──
    print()
    print("  ┌──────┬─────────────────────────────────┬─────────────────────────────────┬────────┐")
    print("  │      │          llama.cpp               │            MLX                  │        │")
    print("  │ Conc ├──────────┬──────────┬────────────┼──────────┬──────────┬────────────┤  倍率  │")
    print("  │      │ tok/s    │ Avg (ms) │ P95 (ms)   │ tok/s    │ Avg (ms) │ P95 (ms)   │        │")
    print("  ├──────┼──────────┼──────────┼────────────┼──────────┼──────────┼────────────┼────────┤")

    for c in CONCURRENCIES:
        ll = llama_results.get(c)
        mx = mlx_results.get(c)
        if not ll or not mx:
            continue
        ratio = mx.agg_tok_per_sec / ll.agg_tok_per_sec if ll.agg_tok_per_sec > 0 else 0
        print(
            f"  │ {c:>4} │ {ll.agg_tok_per_sec:>8.1f} │ {ll.avg_latency:>8.0f} │ {ll.p95:>10.0f} │"
            f" {mx.agg_tok_per_sec:>8.1f} │ {mx.avg_latency:>8.0f} │ {mx.p95:>10.0f} │ {ratio:>5.2f}x │"
        )

    print("  └──────┴──────────┴──────────┴────────────┴──────────┴──────────┴────────────┴────────┘")

    # ── Memory table ──
    print()
    print("  ┌──────┬──────────────────┬──────────────────┐")
    print("  │ Conc │ llama.cpp (MB)   │   MLX (MB)       │")
    print("  ├──────┼──────────────────┼──────────────────┤")

    for c in CONCURRENCIES:
        ll = llama_results.get(c)
        mx = mlx_results.get(c)
        if not ll or not mx:
            continue
        print(f"  │ {c:>4} │ {ll.memory_rss_mb:>12.0f}     │ {mx.memory_rss_mb:>12.0f}     │")

    print("  └──────┴──────────────────┴──────────────────┘")
    print()


def save_results(llama_results: dict[int, BenchResult], mlx_results: dict[int, BenchResult]):
    rows = []
    for c in CONCURRENCIES:
        ll = llama_results.get(c)
        mx = mlx_results.get(c)
        if not ll or not mx:
            continue
        ratio = mx.agg_tok_per_sec / ll.agg_tok_per_sec if ll.agg_tok_per_sec > 0 else 0
        rows.append({
            "concurrency": c,
            "llama": {
                "agg_tok_per_sec": round(ll.agg_tok_per_sec, 2),
                "avg_latency_ms": round(ll.avg_latency, 1),
                "p95_latency_ms": round(ll.p95, 1),
                "memory_rss_mb": round(ll.memory_rss_mb, 0),
                "successful": ll.successful,
                "failed": ll.failed,
                "wall_time_sec": round(ll.wall_time_sec, 3),
                "total_prompt_tokens": ll.total_prompt_tokens,
                "total_completion_tokens": ll.total_completion_tokens,
            },
            "mlx": {
                "agg_tok_per_sec": round(mx.agg_tok_per_sec, 2),
                "avg_latency_ms": round(mx.avg_latency, 1),
                "p95_latency_ms": round(mx.p95, 1),
                "memory_rss_mb": round(mx.memory_rss_mb, 0),
                "successful": mx.successful,
                "failed": mx.failed,
                "wall_time_sec": round(mx.wall_time_sec, 3),
                "total_prompt_tokens": mx.total_prompt_tokens,
                "total_completion_tokens": mx.total_completion_tokens,
            },
            "ratio_mlx_over_llama": round(ratio, 3),
        })

    out = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "config": {
            "llama_model": LLAMA_MODEL,
            "mlx_model": MLX_MODEL,
            "prompt_tokens_approx": 512,
            "max_output_tokens": MAX_TOKENS,
            "temperature": TEMPERATURE,
            "samples_per_concurrency": SAMPLES_PER_CONC,
            "concurrency_levels": CONCURRENCIES,
        },
        "results": rows,
    }

    with open(OUTPUT_PATH, "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    print(f"  Results saved to {OUTPUT_PATH}")


# ── Main ───────────────────────────────────────────────────────────

async def main():
    print()
    print("=" * 70)
    print("  Hayabusa Qwen3.5-9B Benchmark")
    print(f"  llama.cpp: {LLAMA_MODEL}")
    print(f"  MLX:       {MLX_MODEL}")
    print(f"  Prompt ≈512tok  Output={MAX_TOKENS}tok  Samples={SAMPLES_PER_CONC}/conc")
    print(f"  Concurrency: {CONCURRENCIES}")
    print("=" * 70)
    print()

    # ── Start llama.cpp server ──
    print("[1/2] Starting llama.cpp server on port", LLAMA_PORT)
    llama_proc = start_server(LLAMA_MODEL, "llama", LLAMA_PORT, slots=20)
    print(f"  PID={llama_proc.pid}, waiting for ready...")
    if not await wait_for_server(LLAMA_PORT, timeout=120):
        print("ERROR: llama.cpp server failed to start")
        kill_server(llama_proc)
        sys.exit(1)
    print("  llama.cpp server ready.")

    # ── Start MLX server ──
    print("[2/2] Starting MLX server on port", MLX_PORT)
    mlx_proc = start_server(MLX_MODEL, "mlx", MLX_PORT, slots=20)
    print(f"  PID={mlx_proc.pid}, waiting for ready...")
    if not await wait_for_server(MLX_PORT, timeout=300):
        print("ERROR: MLX server failed to start")
        kill_server(llama_proc)
        kill_server(mlx_proc)
        sys.exit(1)
    print("  MLX server ready.")
    print()

    llama_results: dict[int, BenchResult] = {}
    mlx_results: dict[int, BenchResult] = {}

    try:
        for conc in CONCURRENCIES:
            print(f"── Concurrency {conc} ──")

            # llama.cpp
            lr = await run_bench(
                LLAMA_PORT, llama_proc.pid, "llama.cpp",
                conc, SAMPLES_PER_CONC
            )
            llama_results[conc] = lr

            # MLX
            mr = await run_bench(
                MLX_PORT, mlx_proc.pid, "MLX",
                conc, SAMPLES_PER_CONC
            )
            mlx_results[conc] = mr
            print()

        print_table(llama_results, mlx_results)
        save_results(llama_results, mlx_results)

    finally:
        print("  Shutting down servers...")
        kill_server(llama_proc)
        kill_server(mlx_proc)
        print("  Done.")


if __name__ == "__main__":
    asyncio.run(main())
