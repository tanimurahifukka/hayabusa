#!/usr/bin/env python3
"""Hayabusa Cluster Benchmark: Single vs Cluster mode.

Tests whether cluster mode (2 nodes on same machine) improves throughput
compared to a single node.

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

SINGLE_PORT = 8090
CLUSTER_PORT_1 = 8091
CLUSTER_PORT_2 = 8092

MAX_TOKENS = 128
TEMPERATURE = 0.0

CONCURRENCIES = [1, 2, 4, 8]
SAMPLES_PER_CONC = 10

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_PATH = SCRIPT_DIR / "bench_cluster.json"

# Single mode: all slots on one server
SINGLE_SLOTS = 8
# Cluster mode: split across two servers
CLUSTER_SLOTS_EACH = 4

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
    try:
        out = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(pid)],
            text=True, timeout=5
        ).strip()
        return int(out) / 1024.0 if out else 0.0
    except Exception:
        return 0.0


def start_server(
    model: str, port: int, slots: int,
    cluster: bool = False, backend: str = "llama"
) -> subprocess.Popen:
    env = os.environ.copy()
    env["HAYABUSA_PORT"] = str(port)
    cmd = [str(HAYABUSA_BIN), model, "--backend", backend, "--slots", str(slots)]
    if backend == "llama":
        cmd += ["--ctx-per-slot", "4096"]
    if cluster:
        cmd.append("--cluster")
    proc = subprocess.Popen(
        cmd, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True
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
    port: int, pids: list[int], target_name: str,
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

    # Measure memory
    total_mem = sum(get_rss_mb(pid) for pid in pids)

    # Run
    async with aiohttp.ClientSession() as session:
        sys.stderr.write(f"  [{target_name}] conc={concurrency}, {num_samples} reqs... ")
        sys.stderr.flush()

        requests = [messages] * num_samples

        t0 = time.perf_counter()
        tasks = [call_api(session, url, msgs, semaphore) for msgs in requests]
        results = await asyncio.gather(*tasks)
        wall_time = time.perf_counter() - t0

    # Memory after
    total_mem_after = sum(get_rss_mb(pid) for pid in pids)
    peak_mem = max(total_mem, total_mem_after)

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

    sys.stderr.write(
        f"tok/s={bench.agg_tok_per_sec:.1f}  "
        f"avg={bench.avg_latency:.0f}ms  "
        f"p95={bench.p95:.0f}ms  "
        f"mem={peak_mem:.0f}MB\n"
    )
    return bench


# ── Display ────────────────────────────────────────────────────────

def print_table(
    single_results: dict[int, BenchResult],
    cluster_results: dict[int, BenchResult],
):
    print()
    print("=" * 100)
    print("  Hayabusa Cluster Benchmark — Single Node vs 2-Node Cluster")
    print(f"  Model: Qwen3.5-9B-Q4_K_M | Output={MAX_TOKENS} tok | Samples={SAMPLES_PER_CONC}/conc")
    print(f"  Single: {SINGLE_SLOTS} slots | Cluster: 2x{CLUSTER_SLOTS_EACH} slots")
    print("=" * 100)

    print()
    print("  ┌──────┬───────────────────────────────────────┬───────────────────────────────────────┬────────┐")
    print("  │      │          Single ({} slots)             │       Cluster (2x{} slots)            │        │".format(SINGLE_SLOTS, CLUSTER_SLOTS_EACH))
    print("  │ Conc ├──────────┬──────────┬────────┬────────┼──────────┬──────────┬────────┬────────┤  倍率  │")
    print("  │      │ tok/s    │ Avg (ms) │P95 (ms)│Mem(MB) │ tok/s    │ Avg (ms) │P95 (ms)│Mem(MB) │        │")
    print("  ├──────┼──────────┼──────────┼────────┼────────┼──────────┼──────────┼────────┼────────┼────────┤")

    for c in CONCURRENCIES:
        s = single_results.get(c)
        cl = cluster_results.get(c)
        if not s or not cl:
            continue
        ratio = cl.agg_tok_per_sec / s.agg_tok_per_sec if s.agg_tok_per_sec > 0 else 0
        print(
            f"  │ {c:>4} │ {s.agg_tok_per_sec:>8.1f} │ {s.avg_latency:>8.0f} │{s.p95:>7.0f} │{s.memory_rss_mb:>7.0f} │"
            f" {cl.agg_tok_per_sec:>8.1f} │ {cl.avg_latency:>8.0f} │{cl.p95:>7.0f} │{cl.memory_rss_mb:>7.0f} │ {ratio:>5.2f}x │"
        )

    print("  └──────┴──────────┴──────────┴────────┴────────┴──────────┴──────────┴────────┴────────┴────────┘")
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
                "slots": SINGLE_SLOTS,
                "agg_tok_per_sec": round(s.agg_tok_per_sec, 2),
                "avg_latency_ms": round(s.avg_latency, 1),
                "p50_latency_ms": round(s.p50, 1),
                "p95_latency_ms": round(s.p95, 1),
                "memory_rss_mb": round(s.memory_rss_mb, 0),
                "successful": s.successful,
                "failed": s.failed,
                "wall_time_sec": round(s.wall_time_sec, 3),
                "total_completion_tokens": s.total_completion_tokens,
            },
            "cluster": {
                "nodes": 2,
                "slots_each": CLUSTER_SLOTS_EACH,
                "agg_tok_per_sec": round(cl.agg_tok_per_sec, 2),
                "avg_latency_ms": round(cl.avg_latency, 1),
                "p50_latency_ms": round(cl.p50, 1),
                "p95_latency_ms": round(cl.p95, 1),
                "memory_rss_mb": round(cl.memory_rss_mb, 0),
                "successful": cl.successful,
                "failed": cl.failed,
                "wall_time_sec": round(cl.wall_time_sec, 3),
                "total_completion_tokens": cl.total_completion_tokens,
            },
            "ratio_cluster_over_single": round(ratio, 3),
        })

    out = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "config": {
            "model": MODEL,
            "backend": "llama",
            "max_output_tokens": MAX_TOKENS,
            "temperature": TEMPERATURE,
            "samples_per_concurrency": SAMPLES_PER_CONC,
            "concurrency_levels": CONCURRENCIES,
            "single_slots": SINGLE_SLOTS,
            "cluster_slots_each": CLUSTER_SLOTS_EACH,
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
    print(f"  Model: {Path(MODEL).name}")
    print(f"  Single: {SINGLE_SLOTS} slots on port {SINGLE_PORT}")
    print(f"  Cluster: 2x{CLUSTER_SLOTS_EACH} slots on ports {CLUSTER_PORT_1},{CLUSTER_PORT_2}")
    print(f"  Output={MAX_TOKENS}tok  Samples={SAMPLES_PER_CONC}/conc")
    print(f"  Concurrency: {CONCURRENCIES}")
    print("=" * 70)
    print()

    # ════════════════════════════════════════════════════════════════
    # Phase 1: Single node benchmark
    # ════════════════════════════════════════════════════════════════
    print("━" * 50)
    print("  Phase 1: Single Node")
    print("━" * 50)

    print(f"  Starting single server on port {SINGLE_PORT} ({SINGLE_SLOTS} slots)...")
    single_proc = start_server(MODEL, SINGLE_PORT, SINGLE_SLOTS, cluster=False)
    print(f"  PID={single_proc.pid}, waiting for ready...")

    if not await wait_for_server(SINGLE_PORT):
        print("ERROR: Single server failed to start")
        kill_server(single_proc)
        sys.exit(1)
    print("  Single server ready.\n")

    single_results: dict[int, BenchResult] = {}
    try:
        for conc in CONCURRENCIES:
            print(f"  ── Concurrency {conc} ──")
            r = await run_bench(
                SINGLE_PORT, [single_proc.pid], "Single",
                conc, SAMPLES_PER_CONC
            )
            single_results[conc] = r
    finally:
        print("  Shutting down single server...")
        kill_server(single_proc)
        # Wait for port to free up
        await asyncio.sleep(3)

    # ════════════════════════════════════════════════════════════════
    # Phase 2: Cluster mode benchmark
    # ════════════════════════════════════════════════════════════════
    print()
    print("━" * 50)
    print("  Phase 2: Cluster Mode (2 nodes)")
    print("━" * 50)

    print(f"  Starting cluster node 1 on port {CLUSTER_PORT_1} ({CLUSTER_SLOTS_EACH} slots)...")
    cluster_proc_1 = start_server(MODEL, CLUSTER_PORT_1, CLUSTER_SLOTS_EACH, cluster=True)
    print(f"  Node 1 PID={cluster_proc_1.pid}, waiting for ready...")

    if not await wait_for_server(CLUSTER_PORT_1):
        print("ERROR: Cluster node 1 failed to start")
        kill_server(cluster_proc_1)
        sys.exit(1)
    print("  Cluster node 1 ready.")

    print(f"  Starting cluster node 2 on port {CLUSTER_PORT_2} ({CLUSTER_SLOTS_EACH} slots)...")
    cluster_proc_2 = start_server(MODEL, CLUSTER_PORT_2, CLUSTER_SLOTS_EACH, cluster=True)
    print(f"  Node 2 PID={cluster_proc_2.pid}, waiting for ready...")

    if not await wait_for_server(CLUSTER_PORT_2):
        print("ERROR: Cluster node 2 failed to start")
        kill_server(cluster_proc_1)
        kill_server(cluster_proc_2)
        sys.exit(1)
    print("  Cluster node 2 ready.")

    # Wait for Bonjour discovery
    print("  Waiting for Bonjour peer discovery (5 sec)...")
    await asyncio.sleep(5)

    # Check cluster status
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                f"http://localhost:{CLUSTER_PORT_1}/v1/cluster/status",
                timeout=aiohttp.ClientTimeout(total=10)
            ) as resp:
                status = await resp.json()
                peers = status.get("peers", [])
                print(f"  Cluster status: {len(peers)} peer(s) discovered")
                for p in peers:
                    print(f"    - {p.get('id', '?')}: {p.get('host', '?')}:{p.get('port', '?')}")
    except Exception as e:
        print(f"  Warning: Could not check cluster status: {e}")

    print()

    cluster_results: dict[int, BenchResult] = {}
    try:
        for conc in CONCURRENCIES:
            print(f"  ── Concurrency {conc} ──")
            r = await run_bench(
                CLUSTER_PORT_1,
                [cluster_proc_1.pid, cluster_proc_2.pid],
                "Cluster",
                conc, SAMPLES_PER_CONC
            )
            cluster_results[conc] = r
    finally:
        print("  Shutting down cluster servers...")
        kill_server(cluster_proc_1)
        kill_server(cluster_proc_2)

    # ════════════════════════════════════════════════════════════════
    # Results
    # ════════════════════════════════════════════════════════════════
    print_table(single_results, cluster_results)
    save_results(single_results, cluster_results)


if __name__ == "__main__":
    asyncio.run(main())
