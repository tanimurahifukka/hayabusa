#!/usr/bin/env python3
"""
Hayabusa Bandwidth Reduction Benchmark
=======================================
Compares: baseline, speculative decoding, KV cache quantization, both combined.
Measures: tok/s, acceptance rate, memory usage, BERTScore F1.
Concurrency: 1, 4, 8.

Usage:
    python3 scripts/bench_bandwidth.py \
        --model models/Qwen3.5-9B-Q4_K_M.gguf \
        --draft-model models/Qwen3.5-1B-Q4_K_M.gguf \
        --binary .build/release/Hayabusa

Results saved to scripts/bench_bandwidth.json
"""

import argparse
import asyncio
import json
import os
import signal
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path

import aiohttp

# Reference responses for BERTScore comparison
PROMPTS = [
    {"role": "user", "content": "Explain quantum computing in 3 sentences."},
    {"role": "user", "content": "Write a Python function to find prime numbers up to N."},
    {"role": "user", "content": "What are the main differences between TCP and UDP?"},
    {"role": "user", "content": "Describe the process of photosynthesis briefly."},
    {"role": "user", "content": "How does a neural network learn from data?"},
]

BASE_URL = "http://127.0.0.1:{port}"


@dataclass
class BenchResult:
    mode: str
    concurrency: int
    total_requests: int = 0
    total_tokens: int = 0
    elapsed_sec: float = 0.0
    tok_per_sec: float = 0.0
    avg_latency_ms: float = 0.0
    p99_latency_ms: float = 0.0
    acceptance_rate: float = 0.0
    rss_bytes: int = 0
    free_bytes: int = 0
    memory_pressure: str = ""
    responses: list = field(default_factory=list)
    bert_score_f1: float = 0.0


def parse_args():
    parser = argparse.ArgumentParser(description="Hayabusa bandwidth reduction benchmark")
    parser.add_argument("--model", required=True, help="Path to target model (GGUF)")
    parser.add_argument("--draft-model", required=True, help="Path to draft model (GGUF)")
    parser.add_argument("--binary", default=".build/release/Hayabusa", help="Hayabusa binary path")
    parser.add_argument("--port", type=int, default=8090, help="Server port")
    parser.add_argument("--slots", type=int, default=4, help="Number of slots")
    parser.add_argument("--ctx-per-slot", type=int, default=4096, help="Context per slot")
    parser.add_argument("--speculative-tokens", type=int, default=4, help="Speculative lookahead")
    parser.add_argument("--max-tokens", type=int, default=128, help="Max tokens per request")
    parser.add_argument("--output", default="scripts/bench_bandwidth.json", help="Output JSON path")
    parser.add_argument("--skip-bert", action="store_true", help="Skip BERTScore computation")
    return parser.parse_args()


def start_server(binary, args_list, port, timeout=60):
    """Start Hayabusa server and wait for health check."""
    env = os.environ.copy()
    env["HAYABUSA_PORT"] = str(port)

    proc = subprocess.Popen(
        [binary] + args_list,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )

    # Wait for server to be ready
    import urllib.request
    start = time.time()
    while time.time() - start < timeout:
        try:
            resp = urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=2)
            if resp.status == 200:
                print(f"  Server ready (PID {proc.pid})")
                return proc
        except Exception:
            pass
        time.sleep(0.5)

    proc.kill()
    raise TimeoutError(f"Server failed to start within {timeout}s")


def stop_server(proc):
    """Stop server gracefully."""
    if proc and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    time.sleep(1)


async def send_request(session, port, prompt, max_tokens):
    """Send a single chat completion request."""
    url = f"http://127.0.0.1:{port}/v1/chat/completions"
    payload = {
        "messages": [prompt],
        "max_tokens": max_tokens,
        "temperature": 0.1,
    }
    start = time.monotonic()
    async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=120)) as resp:
        data = await resp.json()
        elapsed = time.monotonic() - start

    text = ""
    tokens = 0
    if "choices" in data and data["choices"]:
        text = data["choices"][0].get("message", {}).get("content", "")
    if "usage" in data and data["usage"]:
        tokens = data["usage"].get("completion_tokens", 0)

    return {
        "text": text,
        "tokens": tokens,
        "latency_ms": elapsed * 1000,
    }


async def run_benchmark(port, concurrency, max_tokens, num_rounds=3):
    """Run benchmark with given concurrency level."""
    results = []
    latencies = []

    async with aiohttp.ClientSession() as session:
        for _ in range(num_rounds):
            tasks = []
            for i in range(concurrency):
                prompt = PROMPTS[i % len(PROMPTS)]
                tasks.append(send_request(session, port, prompt, max_tokens))

            start = time.monotonic()
            round_results = await asyncio.gather(*tasks, return_exceptions=True)
            elapsed = time.monotonic() - start

            for r in round_results:
                if isinstance(r, Exception):
                    print(f"    Request failed: {r}")
                    continue
                results.append(r)
                latencies.append(r["latency_ms"])

    return results, latencies


async def get_stats(port):
    """Fetch /v1/stats endpoint."""
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(f"http://127.0.0.1:{port}/v1/stats", timeout=aiohttp.ClientTimeout(total=5)) as resp:
                return await resp.json()
    except Exception:
        return {}


async def get_memory(port):
    """Fetch /v1/memory endpoint."""
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(f"http://127.0.0.1:{port}/v1/memory", timeout=aiohttp.ClientTimeout(total=5)) as resp:
                return await resp.json()
    except Exception:
        return {}


def compute_bert_score(responses_a, responses_b):
    """Compute BERTScore F1 between baseline and optimized responses."""
    try:
        from bert_score import score as bert_score_fn
    except ImportError:
        print("  [SKIP] bert-score not installed (pip install bert-score)")
        return 0.0

    refs = [r["text"] for r in responses_a if r["text"]]
    cands = [r["text"] for r in responses_b if r["text"]]

    # Align lengths
    min_len = min(len(refs), len(cands))
    if min_len == 0:
        return 0.0
    refs = refs[:min_len]
    cands = cands[:min_len]

    _, _, f1 = bert_score_fn(cands, refs, lang="en", verbose=False)
    return float(f1.mean())


async def run_mode(mode, binary, model_args, port, max_tokens, concurrencies):
    """Run benchmark for a specific mode at all concurrency levels."""
    print(f"\n{'='*60}")
    print(f"Mode: {mode}")
    print(f"{'='*60}")

    proc = start_server(binary, model_args, port)
    results = []

    try:
        for conc in concurrencies:
            print(f"\n  Concurrency: {conc}")
            bench_results, latencies = await run_benchmark(port, conc, max_tokens)

            if not bench_results:
                print("    No successful requests!")
                continue

            total_tokens = sum(r["tokens"] for r in bench_results)
            total_elapsed = sum(r["latency_ms"] for r in bench_results) / 1000.0
            tok_per_sec = total_tokens / total_elapsed if total_elapsed > 0 else 0
            avg_latency = sum(latencies) / len(latencies) if latencies else 0
            p99_latency = sorted(latencies)[int(len(latencies) * 0.99)] if latencies else 0

            # Get stats
            stats = await get_stats(port)
            memory = await get_memory(port)

            acceptance_rate = 0.0
            if "speculative" in stats and stats["speculative"].get("enabled"):
                acceptance_rate = float(stats["speculative"].get("acceptanceRate", 0))

            result = BenchResult(
                mode=mode,
                concurrency=conc,
                total_requests=len(bench_results),
                total_tokens=total_tokens,
                elapsed_sec=total_elapsed,
                tok_per_sec=tok_per_sec,
                avg_latency_ms=avg_latency,
                p99_latency_ms=p99_latency,
                acceptance_rate=acceptance_rate,
                rss_bytes=memory.get("rssBytes", 0),
                free_bytes=memory.get("freeEstimate", 0),
                memory_pressure=memory.get("pressure", "unknown"),
                responses=[r["text"][:200] for r in bench_results[:5]],  # Save first 5 truncated
            )
            results.append(result)

            print(f"    tok/s:       {tok_per_sec:.1f}")
            print(f"    Avg latency: {avg_latency:.0f}ms")
            print(f"    P99 latency: {p99_latency:.0f}ms")
            print(f"    Memory RSS:  {memory.get('rssBytes', 0) / 1024**3:.1f} GB")
            if acceptance_rate > 0:
                print(f"    Accept rate: {acceptance_rate:.1%}")

    finally:
        stop_server(proc)

    return results


async def main():
    args = parse_args()
    concurrencies = [1, 4, 8]
    all_results = []
    baseline_responses = []

    # Mode 1: Baseline
    baseline_args = [args.model, "--backend", "llama", "--slots", str(args.slots), "--ctx-per-slot", str(args.ctx_per_slot)]
    baseline_results = await run_mode("baseline", args.binary, baseline_args, args.port, args.max_tokens, concurrencies)
    all_results.extend(baseline_results)
    if baseline_results:
        baseline_responses = baseline_results[0].responses

    # Mode 2: Speculative Decoding
    spec_args = [
        "--draft-model", args.draft_model,
        "--target-model", args.model,
        "--speculative-tokens", str(args.speculative_tokens),
        "--slots", str(args.slots),
        "--ctx-per-slot", str(args.ctx_per_slot),
    ]
    spec_results = await run_mode("speculative", args.binary, spec_args, args.port, args.max_tokens, concurrencies)
    all_results.extend(spec_results)

    # Mode 3: KV Cache Quantization (int8)
    kv_args = [args.model, "--backend", "llama", "--slots", str(args.slots), "--ctx-per-slot", str(args.ctx_per_slot), "--kv-quantize", "int8"]
    kv_results = await run_mode("kv_quantize_int8", args.binary, kv_args, args.port, args.max_tokens, concurrencies)
    all_results.extend(kv_results)

    # Mode 4: Both (speculative + KV quantize)
    both_args = [
        "--draft-model", args.draft_model,
        "--target-model", args.model,
        "--speculative-tokens", str(args.speculative_tokens),
        "--slots", str(args.slots),
        "--ctx-per-slot", str(args.ctx_per_slot),
        "--kv-quantize", "int8",
    ]
    both_results = await run_mode("speculative+kv_quantize", args.binary, both_args, args.port, args.max_tokens, concurrencies)
    all_results.extend(both_results)

    # Compute BERTScore between baseline and each optimized mode
    if not args.skip_bert and baseline_responses:
        print("\n\nComputing BERTScore F1...")
        for result in all_results:
            if result.mode != "baseline" and result.concurrency == 1 and result.responses:
                f1 = compute_bert_score(
                    [{"text": t} for t in baseline_responses],
                    [{"text": t} for t in result.responses],
                )
                result.bert_score_f1 = f1
                print(f"  {result.mode} vs baseline: F1={f1:.4f}")

    # Summary table
    print("\n\n" + "=" * 80)
    print("SUMMARY")
    print("=" * 80)
    print(f"{'Mode':<30} {'Conc':>5} {'tok/s':>8} {'Avg(ms)':>8} {'RSS(GB)':>8} {'Accept':>8} {'BERT F1':>8}")
    print("-" * 80)
    for r in all_results:
        print(
            f"{r.mode:<30} {r.concurrency:>5} "
            f"{r.tok_per_sec:>8.1f} {r.avg_latency_ms:>8.0f} "
            f"{r.rss_bytes / 1024**3:>8.1f} "
            f"{r.acceptance_rate:>7.1%} "
            f"{r.bert_score_f1:>8.4f}" if r.bert_score_f1 > 0 else
            f"{r.mode:<30} {r.concurrency:>5} "
            f"{r.tok_per_sec:>8.1f} {r.avg_latency_ms:>8.0f} "
            f"{r.rss_bytes / 1024**3:>8.1f} "
            f"{r.acceptance_rate:>7.1%} "
            f"{'---':>8}"
        )

    # Save results
    output = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "config": {
            "model": args.model,
            "draft_model": args.draft_model,
            "slots": args.slots,
            "ctx_per_slot": args.ctx_per_slot,
            "speculative_tokens": args.speculative_tokens,
            "max_tokens": args.max_tokens,
            "concurrencies": concurrencies,
        },
        "results": [asdict(r) for r in all_results],
    }

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(output, f, indent=2)
    print(f"\nResults saved to {output_path}")


if __name__ == "__main__":
    asyncio.run(main())
