#!/usr/bin/env python3
"""Hayabusa Layer Skip Benchmark.

Compares inference throughput and quality across different
layer-skip thresholds (none, 30%, 50%).

Usage:
    python scripts/bench_layer_skip.py [--model MODEL_ID] [--port PORT]

Prerequisites:
    pip install aiohttp bert-score
    # Run analyze_layers.py first to generate layer_importance.json
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

# ── Config ────────────────────────────────────────────────────────

HAYABUSA_BIN = Path("/Users/tanimura/Desktop/Lang/hayabusa/.build/debug/Hayabusa")
MODEL = "mlx-community/Qwen3.5-4B-4bit"
PORT = 8090  # Use different port from main server

MAX_TOKENS = 256
TEMPERATURE = 0.0  # Greedy for reproducibility
NUM_SAMPLES = 20
CONCURRENCY = 1  # Single-stream for clean tok/s measurement

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_PATH = SCRIPT_DIR / "bench_layer_skip.json"

# Skip levels to benchmark
# Sweet spot for Qwen3.5-4B: threshold 0.093 skips 6/32 layers (1.18x speedup, quality OK)
# Above 6 layers (threshold ~0.096) causes degenerate output
SKIP_LEVELS = [
    {"name": "no-skip", "threshold": None, "description": "Baseline (all layers)"},
    {"name": "skip-sweet", "threshold": 0.093, "description": "Sweet spot: skip 6/32 layers (importance ≤ 9.3%)"},
]

# SOAP prompts for benchmarking (subset for speed)
BENCH_PROMPTS = [
    "Write a SOAP note for a 45-year-old male with a 3-day history of headache and low-grade fever.",
    "Create a SOAP note for a 60-year-old diabetic male with an HbA1c of 9.2% at follow-up.",
    "Document a SOAP note for a 3-year-old child with high fever and bilateral ear pain.",
    "Write a SOAP note for a 58-year-old male presenting to the ED with crushing substernal chest pain.",
    "Create a SOAP note for a 29-year-old male with worsening depression and insomnia for 4 weeks.",
    "Document a SOAP note for a 35-year-old with a suspicious changing mole on the back.",
    "Write a SOAP note for a 52-year-old male with newly detected atrial fibrillation.",
    "Create a SOAP note for a 40-year-old non-smoker with a persistent dry cough for 8 weeks.",
    "Document a SOAP note for a 35-year-old female with Graves' disease and exophthalmos.",
    "Write a SOAP note for a 45-year-old with new-onset dysphagia to solids.",
    "Create a SOAP note for a 30-year-old female with optic neuritis and suspected multiple sclerosis.",
    "Document a SOAP note for a 50-year-old with rotator cuff tear and limited shoulder abduction.",
    "Write a SOAP note for a 40-year-old with cellulitis of the right lower extremity.",
    "Create a SOAP note for a 32-year-old at 28 weeks gestation with gestational diabetes.",
    "Document a SOAP note for a 55-year-old with sudden painless vision loss in the right eye.",
    "Write a SOAP note for a 68-year-old with resting tremor and bradykinesia.",
    "Create a SOAP note for a 25-year-old with cluster headaches occurring nightly.",
    "Document a SOAP note for a 65-year-old with lumbar spinal stenosis and neurogenic claudication.",
    "Write a SOAP note for a 28-year-old with a positive HIV test and initial evaluation.",
    "Create a SOAP note for a 70-year-old with cataracts and progressive visual decline.",
]


# ── Data classes ──────────────────────────────────────────────────

@dataclass
class RequestResult:
    latency_ms: float
    prompt_tokens: int
    completion_tokens: int
    tok_per_sec: float
    success: bool
    response_text: str = ""
    error: str | None = None


@dataclass
class BenchResult:
    name: str
    description: str
    threshold: float | None
    results: list[RequestResult] = field(default_factory=list)

    @property
    def successful(self) -> int:
        return sum(1 for r in self.results if r.success)

    @property
    def avg_tok_per_sec(self) -> float:
        tps = [r.tok_per_sec for r in self.results if r.success and r.tok_per_sec > 0]
        return statistics.mean(tps) if tps else 0

    @property
    def median_tok_per_sec(self) -> float:
        tps = [r.tok_per_sec for r in self.results if r.success and r.tok_per_sec > 0]
        return statistics.median(tps) if tps else 0

    @property
    def avg_latency_ms(self) -> float:
        lats = [r.latency_ms for r in self.results if r.success]
        return statistics.mean(lats) if lats else 0

    @property
    def total_completion_tokens(self) -> int:
        return sum(r.completion_tokens for r in self.results if r.success)

    @property
    def texts(self) -> list[str]:
        return [r.response_text for r in self.results if r.success and r.response_text]


# ── Server management ─────────────────────────────────────────────

def start_server(port: int, model: str, threshold: float | None) -> subprocess.Popen:
    env = os.environ.copy()
    env["HAYABUSA_PORT"] = str(port)
    cmd = [str(HAYABUSA_BIN), model, "--backend", "mlx", "--slots", "1"]
    if threshold is not None:
        cmd += ["--layer-skip", str(threshold), "--task", "soap"]
    proc = subprocess.Popen(
        cmd, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
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
        await asyncio.sleep(2)
    return False


def kill_server(proc: subprocess.Popen):
    try:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=15)
    except Exception:
        proc.kill()
        proc.wait(timeout=5)


async def get_memory_info(port: int) -> dict | None:
    try:
        async with aiohttp.ClientSession() as s:
            async with s.get(
                f"http://localhost:{port}/v1/memory",
                timeout=aiohttp.ClientTimeout(total=5),
            ) as resp:
                return await resp.json()
    except Exception:
        return None


async def get_stats(port: int) -> dict | None:
    try:
        async with aiohttp.ClientSession() as s:
            async with s.get(
                f"http://localhost:{port}/v1/stats",
                timeout=aiohttp.ClientTimeout(total=5),
            ) as resp:
                return await resp.json()
    except Exception:
        return None


# ── API call ──────────────────────────────────────────────────────

async def call_api(
    session: aiohttp.ClientSession,
    url: str,
    prompt: str,
) -> RequestResult:
    payload = {
        "model": "local",
        "messages": [
            {"role": "system", "content": "You are a medical professional. Write detailed SOAP notes."},
            {"role": "user", "content": prompt},
        ],
        "max_tokens": MAX_TOKENS,
        "temperature": TEMPERATURE,
    }
    t0 = time.perf_counter()
    try:
        async with session.post(
            url, json=payload,
            timeout=aiohttp.ClientTimeout(total=600),
        ) as resp:
            raw = await resp.read()
            data = json.loads(raw.decode("utf-8", errors="replace"), strict=False)
            elapsed_ms = (time.perf_counter() - t0) * 1000

            usage = data.get("usage", {})
            completion_tokens = usage.get("completion_tokens", 0)
            tok_per_sec = completion_tokens / (elapsed_ms / 1000) if elapsed_ms > 0 else 0

            content = ""
            choices = data.get("choices", [])
            if choices:
                content = choices[0].get("message", {}).get("content", "")

            return RequestResult(
                latency_ms=elapsed_ms,
                prompt_tokens=usage.get("prompt_tokens", 0),
                completion_tokens=completion_tokens,
                tok_per_sec=tok_per_sec,
                success=True,
                response_text=content,
            )
    except Exception as e:
        elapsed_ms = (time.perf_counter() - t0) * 1000
        return RequestResult(
            latency_ms=elapsed_ms, prompt_tokens=0,
            completion_tokens=0, tok_per_sec=0,
            success=False, error=str(e),
        )


# ── BERTScore ─────────────────────────────────────────────────────

def compute_bertscore(references: list[str], candidates: list[str]) -> dict | None:
    """Compute BERTScore F1 between reference (no-skip) and candidate (skip) outputs."""
    try:
        from bert_score import score as bert_score
    except ImportError:
        sys.stderr.write("  WARNING: bert-score not installed, skipping quality check\n")
        sys.stderr.write("  Install with: pip install bert-score\n")
        return None

    if not references or not candidates:
        return None

    # Truncate to matching length
    n = min(len(references), len(candidates))
    refs = references[:n]
    cands = candidates[:n]

    sys.stderr.write(f"  Computing BERTScore for {n} pairs...\n")
    P, R, F1 = bert_score(cands, refs, lang="en", verbose=False)

    return {
        "precision": round(P.mean().item(), 4),
        "recall": round(R.mean().item(), 4),
        "f1": round(F1.mean().item(), 4),
        "num_pairs": n,
    }


# ── Benchmark runner ──────────────────────────────────────────────

async def run_benchmark(port: int, level: dict) -> BenchResult:
    name = level["name"]
    url = f"http://localhost:{port}/v1/chat/completions"
    bench = BenchResult(
        name=name,
        description=level["description"],
        threshold=level["threshold"],
    )

    # Warmup
    async with aiohttp.ClientSession() as session:
        sys.stderr.write(f"  [{name}] warmup... ")
        sys.stderr.flush()
        warm = {
            "model": "local",
            "messages": [{"role": "user", "content": "Say hi."}],
            "max_tokens": 8,
            "temperature": 0,
        }
        try:
            async with session.post(url, json=warm,
                                    timeout=aiohttp.ClientTimeout(total=120)) as resp:
                await resp.read()
        except Exception:
            pass
        sys.stderr.write("done\n")

    # Run samples
    async with aiohttp.ClientSession() as session:
        for i, prompt in enumerate(BENCH_PROMPTS[:NUM_SAMPLES]):
            sys.stderr.write(f"\r  [{name}] sample {i + 1}/{NUM_SAMPLES}...")
            sys.stderr.flush()
            result = await call_api(session, url, prompt)
            bench.results.append(result)
            if not result.success:
                sys.stderr.write(f" ERROR: {result.error}\n")

    sys.stderr.write(
        f"\r  [{name}] {bench.successful}/{NUM_SAMPLES} ok, "
        f"avg={bench.avg_tok_per_sec:.1f} tok/s, "
        f"median={bench.median_tok_per_sec:.1f} tok/s\n"
    )
    return bench


# ── Display ───────────────────────────────────────────────────────

def print_table(results: dict[str, BenchResult], bert_scores: dict[str, dict | None]):
    print()
    print("=" * 85)
    print("  Hayabusa Layer Skip Benchmark")
    print(f"  Backend: MLX | Output: {MAX_TOKENS} tok | Samples: {NUM_SAMPLES}")
    print("=" * 85)

    print()
    hdr = (
        "  ┌────────────┬────────────┬────────────┬────────────┬──────────┬────────────────┐\n"
        "  │ Config     │  Avg tok/s │  Med tok/s │  Avg (ms)  │  Memory  │ BERTScore F1   │\n"
        "  ├────────────┼────────────┼────────────┼────────────┼──────────┼────────────────┤"
    )
    print(hdr)

    for name in ["no-skip", "skip-10pct", "skip-15pct"]:
        r = results.get(name)
        if not r:
            continue
        mem = r.__dict__.get("_memory_rss_mb", "N/A")
        bs = bert_scores.get(name)
        f1_str = f"{bs['f1']:.4f}" if bs else "baseline"
        quality = ""
        if bs and bs["f1"] < 0.84:
            quality = " ⚠️"

        print(
            f"  │ {name:<10} │ {r.avg_tok_per_sec:>10.1f} │ {r.median_tok_per_sec:>10.1f} │"
            f" {r.avg_latency_ms:>10.0f} │ {str(mem):>8} │ {f1_str:<14}{quality} │"
        )

    print("  └────────────┴────────────┴────────────┴────────────┴──────────┴────────────────┘")

    # Speedup comparison
    baseline = results.get("no-skip")
    if baseline and baseline.avg_tok_per_sec > 0:
        print()
        print("  Speedup vs baseline:")
        for name in ["skip-10pct", "skip-15pct"]:
            r = results.get(name)
            if r:
                ratio = r.avg_tok_per_sec / baseline.avg_tok_per_sec
                print(f"    {name}: {ratio:.2f}x")


def save_results(
    results: dict[str, BenchResult],
    bert_scores: dict[str, dict | None],
    memory_info: dict[str, dict | None],
    stats_info: dict[str, dict | None],
):
    rows = []
    baseline_tps = results.get("no-skip")
    baseline_tps_val = baseline_tps.avg_tok_per_sec if baseline_tps else 0

    for name in ["no-skip", "skip-10pct", "skip-15pct"]:
        r = results.get(name)
        if not r:
            continue
        speedup = r.avg_tok_per_sec / baseline_tps_val if baseline_tps_val > 0 else 1.0
        row = {
            "name": name,
            "description": r.description,
            "threshold": r.threshold,
            "avg_tok_per_sec": round(r.avg_tok_per_sec, 2),
            "median_tok_per_sec": round(r.median_tok_per_sec, 2),
            "avg_latency_ms": round(r.avg_latency_ms, 1),
            "total_completion_tokens": r.total_completion_tokens,
            "successful": r.successful,
            "samples": NUM_SAMPLES,
            "speedup": round(speedup, 3),
        }
        if name in bert_scores and bert_scores[name]:
            row["bertscore"] = bert_scores[name]
        if name in memory_info and memory_info[name]:
            row["memory"] = memory_info[name]
        if name in stats_info and stats_info[name]:
            row["server_stats"] = stats_info[name]
        rows.append(row)

    output = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "config": {
            "model": MODEL,
            "backend": "mlx",
            "max_output_tokens": MAX_TOKENS,
            "temperature": TEMPERATURE,
            "num_samples": NUM_SAMPLES,
            "concurrency": CONCURRENCY,
        },
        "results": rows,
    }

    with open(OUTPUT_PATH, "w") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    print(f"\n  Results saved to {OUTPUT_PATH}")


# ── Main ──────────────────────────────────────────────────────────

async def main():
    print()
    print("=" * 65)
    print("  Hayabusa Layer Skip Benchmark")
    print(f"  Model: {MODEL}")
    print(f"  Levels: {', '.join(l['name'] for l in SKIP_LEVELS)}")
    print(f"  Samples: {NUM_SAMPLES} | Max tokens: {MAX_TOKENS}")
    print("=" * 65)

    all_results: dict[str, BenchResult] = {}
    all_memory: dict[str, dict | None] = {}
    all_stats: dict[str, dict | None] = {}

    for level in SKIP_LEVELS:
        name = level["name"]
        print(f"\n{'━' * 50}")
        print(f"  Phase: {name} ({level['description']})")
        print(f"{'━' * 50}")

        # Start server
        proc = start_server(PORT, MODEL, level["threshold"])
        print(f"  Server PID={proc.pid}, waiting for startup...")

        if not await wait_for_server(PORT):
            print(f"  ERROR: Server failed to start for {name}")
            kill_server(proc)
            continue

        print("  Server ready.\n")

        try:
            # Collect memory & stats before benchmark
            mem_before = await get_memory_info(PORT)

            # Run benchmark
            result = await run_benchmark(PORT, level)
            all_results[name] = result

            # Collect memory & stats after benchmark
            all_memory[name] = await get_memory_info(PORT)
            all_stats[name] = await get_stats(PORT)

        finally:
            kill_server(proc)
            await asyncio.sleep(3)

    # Compute BERTScore (skip outputs vs no-skip baseline)
    bert_scores: dict[str, dict | None] = {}
    baseline = all_results.get("no-skip")
    if baseline:
        ref_texts = baseline.texts
        for name, result in all_results.items():
            if name == "no-skip":
                bert_scores[name] = None  # baseline
            else:
                bert_scores[name] = compute_bertscore(ref_texts, result.texts)

    # Display and save
    print_table(all_results, bert_scores)
    save_results(all_results, bert_scores, all_memory, all_stats)


if __name__ == "__main__":
    asyncio.run(main())
