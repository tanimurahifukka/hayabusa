#!/usr/bin/env python3
"""Hayabusa Cluster Benchmark: Single Node vs 2-Node Cluster.

Compares throughput of a single Mac Studio vs Mac Studio + Mac mini cluster.

Usage:
    python scripts/bench_cluster.py
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

HAYABUSA_BIN = Path("/Users/tanimura/Desktop/Lang/hayabusa/.build/debug/Hayabusa")
MODEL = "/Users/tanimura/Desktop/Lang/hayabusa/models/Qwen3.5-9B-Q4_K_M.gguf"

MAC_MINI = "192.168.11.49:8080"
LOCAL_PORT = 8080

MAX_TOKENS = 128
TEMPERATURE = 0.0

CONCURRENCIES = [1, 2, 4, 8, 16, 24, 32, 40]
SAMPLES_PER_CONC = 12

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_PATH = SCRIPT_DIR / "bench_cluster.json"

SLOTS = 4

# ── Prompt ──────────────────────────────────────────────────────────

PROMPT = (
    "You are a knowledgeable computer science professor. "
    "Explain how a modern CPU executes instructions using pipelining. "
    "Cover the five classic pipeline stages: instruction fetch (IF), "
    "instruction decode (ID), execute (EX), memory access (MEM), "
    "and write-back (WB). Discuss pipeline hazards including data hazards, "
    "control hazards, and structural hazards. Give a concrete example."
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

def start_server(port: int, slots: int, peers: str | None = None) -> subprocess.Popen:
    env = os.environ.copy()
    env["HAYABUSA_PORT"] = str(port)
    cmd = [str(HAYABUSA_BIN), MODEL, "--backend", "llama",
           "--slots", str(slots), "--ctx-per-slot", "4096"]
    if peers:
        cmd += ["--peers", peers]
    proc = subprocess.Popen(
        cmd, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True
    )
    return proc


async def wait_for_server(port: int, timeout: int = 180) -> bool:
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
        return RequestResult(
            latency_ms=elapsed, prompt_tokens=0,
            completion_tokens=0, success=False, error=str(e)
        )


# ── Benchmark runner ───────────────────────────────────────────────

async def run_bench(
    port: int, target_name: str,
    concurrency: int, num_samples: int,
) -> BenchResult:
    url = f"http://localhost:{port}/v1/chat/completions"
    messages = [
        {"role": "system", "content": "You are a helpful assistant. Answer in detail."},
        {"role": "user", "content": PROMPT},
    ]

    semaphore = asyncio.Semaphore(concurrency)

    # Warmup
    async with aiohttp.ClientSession() as session:
        sys.stderr.write(f"  [{target_name}] warmup... ")
        sys.stderr.flush()
        warm = {"model": "local", "messages": [{"role": "user", "content": "Say hi."}],
                "max_tokens": 8, "temperature": 0}
        try:
            async with session.post(url, json=warm,
                                    timeout=aiohttp.ClientTimeout(total=120)) as resp:
                await resp.read()
        except Exception:
            pass
        sys.stderr.write("done\n")

    # Run
    async with aiohttp.ClientSession() as session:
        sys.stderr.write(f"  [{target_name}] conc={concurrency}, {num_samples} reqs... ")
        sys.stderr.flush()

        t0 = time.perf_counter()
        tasks = [call_api(session, url, messages, semaphore) for _ in range(num_samples)]
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
            sys.stderr.write(f"\n    ERROR: {e.error}")

    sys.stderr.write(
        f"tok/s={bench.agg_tok_per_sec:.1f}  "
        f"avg={bench.avg_latency:.0f}ms  "
        f"p95={bench.p95:.0f}ms\n"
    )
    return bench


# ── Display ────────────────────────────────────────────────────────

def print_table(
    single_results: dict[int, BenchResult],
    cluster_results: dict[int, BenchResult],
):
    print()
    print("=" * 95)
    print("  Hayabusa Cluster Benchmark")
    print(f"  Single: Mac Studio (llama, {SLOTS} slots)")
    print(f"  Cluster: Mac Studio (llama) + Mac mini (MLX) via --peers")
    print(f"  Output={MAX_TOKENS} tok | Samples={SAMPLES_PER_CONC}/conc")
    print("=" * 95)

    print()
    hdr = (
        "  ┌──────┬──────────────────────────────────┬──────────────────────────────────┬────────┐\n"
        "  │      │        Single (Mac Studio)       │     Cluster (Studio + mini)      │        │\n"
        "  │ Conc ├──────────┬──────────┬─────────────┼──────────┬──────────┬────────────┤  倍率  │\n"
        "  │      │ tok/s    │ Avg (ms) │  P95 (ms)   │ tok/s    │ Avg (ms) │ P95 (ms)   │        │\n"
        "  ├──────┼──────────┼──────────┼─────────────┼──────────┼──────────┼────────────┼────────┤"
    )
    print(hdr)

    for c in CONCURRENCIES:
        s = single_results.get(c)
        cl = cluster_results.get(c)
        if not s or not cl:
            continue
        ratio = cl.agg_tok_per_sec / s.agg_tok_per_sec if s.agg_tok_per_sec > 0 else 0
        print(
            f"  │ {c:>4} │ {s.agg_tok_per_sec:>8.1f} │ {s.avg_latency:>8.0f} │ {s.p95:>11.0f} │"
            f" {cl.agg_tok_per_sec:>8.1f} │ {cl.avg_latency:>8.0f} │ {cl.p95:>10.0f} │ {ratio:>5.2f}x │"
        )

    print("  └──────┴──────────┴──────────┴─────────────┴──────────┴──────────┴────────────┴────────┘")
    print()


def save_results(
    single_results: dict[int, BenchResult],
    cluster_results: dict[int, BenchResult],
):
    rows = []
    for c in CONCURRENCIES:
        s = single_results.get(c)
        cl = cluster_results.get(c)
        if not s or not cl:
            continue
        ratio = cl.agg_tok_per_sec / s.agg_tok_per_sec if s.agg_tok_per_sec > 0 else 0
        rows.append({
            "concurrency": c,
            "single": {
                "agg_tok_per_sec": round(s.agg_tok_per_sec, 2),
                "avg_latency_ms": round(s.avg_latency, 1),
                "p50_latency_ms": round(s.p50, 1),
                "p95_latency_ms": round(s.p95, 1),
                "successful": s.successful, "failed": s.failed,
                "wall_time_sec": round(s.wall_time_sec, 3),
                "total_completion_tokens": s.total_completion_tokens,
            },
            "cluster": {
                "agg_tok_per_sec": round(cl.agg_tok_per_sec, 2),
                "avg_latency_ms": round(cl.avg_latency, 1),
                "p50_latency_ms": round(cl.p50, 1),
                "p95_latency_ms": round(cl.p95, 1),
                "successful": cl.successful, "failed": cl.failed,
                "wall_time_sec": round(cl.wall_time_sec, 3),
                "total_completion_tokens": cl.total_completion_tokens,
            },
            "ratio_cluster_over_single": round(ratio, 3),
        })

    out = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "config": {
            "model": MODEL,
            "single_backend": "llama",
            "cluster": "Mac Studio (llama) + Mac mini (MLX)",
            "max_output_tokens": MAX_TOKENS,
            "temperature": TEMPERATURE,
            "samples_per_concurrency": SAMPLES_PER_CONC,
            "concurrency_levels": CONCURRENCIES,
            "slots": SLOTS,
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
    print("  Hayabusa Cluster Benchmark")
    print(f"  Single: Mac Studio llama ({SLOTS} slots)")
    print(f"  Cluster: Mac Studio + Mac mini ({MAC_MINI})")
    print(f"  Output={MAX_TOKENS}tok  Samples={SAMPLES_PER_CONC}/conc")
    print(f"  Concurrency: {CONCURRENCIES}")
    print("=" * 70)

    # ── Verify Mac mini is alive ──
    print("\n  Checking Mac mini...")
    try:
        async with aiohttp.ClientSession() as s:
            async with s.get(f"http://{MAC_MINI}/health",
                             timeout=aiohttp.ClientTimeout(total=5)) as resp:
                if resp.status != 200:
                    print(f"  ERROR: Mac mini unhealthy (status={resp.status})")
                    sys.exit(1)
    except Exception as e:
        print(f"  ERROR: Cannot reach Mac mini at {MAC_MINI}: {e}")
        sys.exit(1)
    print(f"  Mac mini ({MAC_MINI}) is healthy.\n")

    # ════════════════════════════════════════════════════════════════
    # Phase 1: Single node
    # ════════════════════════════════════════════════════════════════
    print("━" * 50)
    print("  Phase 1: Single Node (Mac Studio only)")
    print("━" * 50)

    single_proc = start_server(LOCAL_PORT, SLOTS)
    print(f"  PID={single_proc.pid}, waiting...")

    if not await wait_for_server(LOCAL_PORT):
        print("ERROR: Server failed to start")
        kill_server(single_proc)
        sys.exit(1)
    print("  Ready.\n")

    single_results: dict[int, BenchResult] = {}
    try:
        for conc in CONCURRENCIES:
            r = await run_bench(LOCAL_PORT, "Single", conc, SAMPLES_PER_CONC)
            single_results[conc] = r
    finally:
        kill_server(single_proc)
        await asyncio.sleep(3)

    # ════════════════════════════════════════════════════════════════
    # Phase 2: Cluster (Mac Studio + Mac mini)
    # ════════════════════════════════════════════════════════════════
    print()
    print("━" * 50)
    print("  Phase 2: Cluster (Mac Studio + Mac mini)")
    print("━" * 50)

    cluster_proc = start_server(LOCAL_PORT, SLOTS, peers=MAC_MINI)
    print(f"  PID={cluster_proc.pid}, waiting...")

    if not await wait_for_server(LOCAL_PORT):
        print("ERROR: Cluster server failed to start")
        kill_server(cluster_proc)
        sys.exit(1)

    # Wait for peer registration
    await asyncio.sleep(5)

    # Verify cluster
    try:
        async with aiohttp.ClientSession() as s:
            async with s.get(f"http://localhost:{LOCAL_PORT}/v1/cluster/status",
                             timeout=aiohttp.ClientTimeout(total=5)) as resp:
                status = await resp.json()
                nodes = status.get("nodes", [])
                remote = [n for n in nodes if not n.get("isLocal")]
                print(f"  Cluster: {len(nodes)} nodes ({len(remote)} remote)")
    except Exception:
        pass
    print()

    cluster_results: dict[int, BenchResult] = {}
    try:
        for conc in CONCURRENCIES:
            r = await run_bench(LOCAL_PORT, "Cluster", conc, SAMPLES_PER_CONC)
            cluster_results[conc] = r
    finally:
        kill_server(cluster_proc)

    # ════════════════════════════════════════════════════════════════
    print_table(single_results, cluster_results)
    save_results(single_results, cluster_results)


if __name__ == "__main__":
    asyncio.run(main())
