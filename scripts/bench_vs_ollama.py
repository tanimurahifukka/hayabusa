#!/usr/bin/env python3
"""Hayabusa vs Ollama v0.19+ ガチ勝負ベンチマーク.

Ollama v0.19 MLXバックエンド対応。TTFT（ストリーミング）、decode速度、
並列スケーリングを全方位で計測する。

Setup:
    # Hayabusa (port 8080):
    .build/debug/Hayabusa mlx-community/Qwen3.5-9B-MLX-4bit --backend mlx

    # Ollama (port 11434, MLX自動選択 v0.19+):
    ollama serve
    ollama pull qwen3.5:latest

Usage:
    python scripts/bench_vs_ollama.py
    python scripts/bench_vs_ollama.py --model qwen3.5:9b --samples 30
    python scripts/bench_vs_ollama.py --concurrency 1 4 8 16 32
    python scripts/bench_vs_ollama.py --max-tokens 256  # longer generation
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

HAYABUSA_BASE = "http://localhost:{port}"
OLLAMA_BASE = "http://localhost:11434"

# 多様なプロンプト（短・中・長 + コード生成）
PROMPTS = [
    # Short - prefill速度テスト
    "What is 2+2?",
    "Say hello in Japanese.",
    "Name three primary colors.",
    # Medium - バランス
    "Explain the difference between a stack and a queue in 2 sentences.",
    "Write a Python function that checks if a number is prime.",
    "What are the SOLID principles? List them briefly.",
    # Long input - prefill負荷テスト
    "Explain how a hash table works. Cover: the hash function, collision resolution strategies (chaining vs open addressing), and time complexity for insert, lookup, and delete operations. Keep it under 150 words.",
    "Compare merge sort and quicksort. Discuss their time complexity in best, average, and worst cases. Also compare space usage and stability. Answer in 4-5 sentences.",
    "What is the CAP theorem in distributed systems? Explain each of the three properties (Consistency, Availability, Partition tolerance) and give a real-world database example for each trade-off.",
    "Describe how garbage collection works in modern JVMs. Cover: generational hypothesis, young generation (Eden + survivor spaces), old generation, mark-and-sweep, G1 collector, and when a full GC is triggered. Keep it under 200 words.",
    # Code generation - decode速度テスト
    "Write a Python implementation of binary search that returns the index or -1. Include type hints.",
    "Write a Swift function that finds the longest common subsequence of two strings. Use dynamic programming.",
]

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_PATH = SCRIPT_DIR / "bench_vs_ollama.json"


# ── Data classes ────────────────────────────────────────────────────

@dataclass
class RequestResult:
    latency_ms: float
    ttft_ms: float  # Time to First Token (streaming)
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
    max_tokens: int = 0
    latencies_ms: list[float] = field(default_factory=list)
    ttfts_ms: list[float] = field(default_factory=list)
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
    def avg_ttft(self) -> float:
        return statistics.mean(self.ttfts_ms) if self.ttfts_ms else 0

    @property
    def p50_ttft(self) -> float:
        return _pct(self.ttfts_ms, 50)

    @property
    def p95_ttft(self) -> float:
        return _pct(self.ttfts_ms, 95)

    @property
    def tok_per_sec(self) -> float:
        return self.total_completion_tokens / self.wall_time_sec if self.wall_time_sec > 0 else 0

    @property
    def decode_tok_per_sec(self) -> float:
        """Per-request average decode speed (excludes TTFT)."""
        speeds = []
        for lat, ttft, idx in zip(self.latencies_ms, self.ttfts_ms, range(len(self.latencies_ms))):
            decode_time = lat - ttft
            if decode_time > 0 and self.total_completion_tokens > 0:
                # Approximate per-request completion tokens
                avg_comp = self.total_completion_tokens / max(self.successful, 1)
                speeds.append(avg_comp / (decode_time / 1000))
        return statistics.mean(speeds) if speeds else 0

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


# ── Streaming API call (TTFT計測) ──────────────────────────────────

async def call_streaming(
    session: aiohttp.ClientSession,
    url: str,
    messages: list[dict],
    model: str,
    max_tokens: int,
    semaphore: asyncio.Semaphore,
) -> RequestResult:
    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
    }

    t0 = time.perf_counter()
    ttft = 0.0
    completion_tokens = 0
    prompt_tokens = 0
    first_token_seen = False

    try:
        async with semaphore:
            async with session.post(
                url, json=payload,
                timeout=aiohttp.ClientTimeout(total=300),
            ) as resp:
                async for line in resp.content:
                    text = line.decode("utf-8", errors="replace").strip()
                    if not text or not text.startswith("data: "):
                        continue
                    data_str = text[6:]
                    if data_str == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data_str)
                    except json.JSONDecodeError:
                        continue

                    if not first_token_seen:
                        delta = chunk.get("choices", [{}])[0].get("delta", {})
                        if delta.get("content"):
                            ttft = (time.perf_counter() - t0) * 1000
                            first_token_seen = True

                    # Track usage from final chunk
                    usage = chunk.get("usage")
                    if usage:
                        prompt_tokens = usage.get("prompt_tokens", prompt_tokens)
                        completion_tokens = usage.get("completion_tokens", completion_tokens)

                elapsed = (time.perf_counter() - t0) * 1000

                # If usage not in stream, estimate from non-streaming
                if completion_tokens == 0:
                    completion_tokens = max_tokens  # rough estimate

                return RequestResult(
                    latency_ms=elapsed,
                    ttft_ms=ttft if ttft > 0 else elapsed,
                    prompt_tokens=prompt_tokens,
                    completion_tokens=completion_tokens,
                    success=True,
                )
    except Exception as e:
        elapsed = (time.perf_counter() - t0) * 1000
        return RequestResult(
            latency_ms=elapsed, ttft_ms=0,
            prompt_tokens=0, completion_tokens=0,
            success=False, error=str(e),
        )


# Non-streaming fallback (usage tracking)
async def call_non_streaming(
    session: aiohttp.ClientSession,
    url: str,
    messages: list[dict],
    model: str,
    max_tokens: int,
    semaphore: asyncio.Semaphore,
) -> RequestResult:
    payload = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": False,
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
                    ttft_ms=elapsed,  # no streaming = no TTFT
                    prompt_tokens=usage.get("prompt_tokens", 0),
                    completion_tokens=usage.get("completion_tokens", 0),
                    success=True,
                )
    except Exception as e:
        elapsed = (time.perf_counter() - t0) * 1000
        return RequestResult(
            latency_ms=elapsed, ttft_ms=0,
            prompt_tokens=0, completion_tokens=0,
            success=False, error=str(e),
        )


# ── Server check ───────────────────────────────────────────────────

async def check_server(base_url: str, name: str) -> bool:
    health_urls = [f"{base_url}/health", f"{base_url}/api/tags"]
    async with aiohttp.ClientSession() as session:
        for url in health_urls:
            try:
                async with session.get(url, timeout=aiohttp.ClientTimeout(total=5)) as resp:
                    if resp.status == 200:
                        return True
            except Exception:
                continue
    return False


async def get_ollama_version() -> str | None:
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                f"{OLLAMA_BASE}/api/version",
                timeout=aiohttp.ClientTimeout(total=5),
            ) as resp:
                data = await resp.json()
                return data.get("version", "unknown")
    except Exception:
        return None


# ── Warmup ─────────────────────────────────────────────────────────

async def warmup(session: aiohttp.ClientSession, url: str, model: str, max_tokens: int):
    sem = asyncio.Semaphore(1)
    for _ in range(3):
        await call_non_streaming(
            session, url,
            [{"role": "user", "content": "Hi"}],
            model, min(max_tokens, 16), sem,
        )


# ── Bench runner ───────────────────────────────────────────────────

async def run_bench(
    url: str, model: str, target_name: str,
    concurrency: int, num_samples: int,
    max_tokens: int, use_streaming: bool,
) -> BenchResult:
    requests = []
    for i in range(num_samples):
        prompt = PROMPTS[i % len(PROMPTS)]
        requests.append([
            {"role": "system", "content": "Answer briefly and precisely."},
            {"role": "user", "content": prompt},
        ])

    semaphore = asyncio.Semaphore(concurrency)
    call_fn = call_streaming if use_streaming else call_non_streaming

    async with aiohttp.ClientSession() as session:
        sys.stderr.write(f"  Warming up {target_name}... ")
        sys.stderr.flush()
        await warmup(session, url, model, max_tokens)
        sys.stderr.write("done\n")
        sys.stderr.write(f"  Running {num_samples} reqs (conc={concurrency}, stream={use_streaming})...\n")

        t0 = time.perf_counter()
        tasks = [
            call_fn(session, url, msgs, model, max_tokens, semaphore)
            for msgs in requests
        ]
        results = await asyncio.gather(*tasks)
        wall_time = time.perf_counter() - t0

    bench = BenchResult(
        target=target_name, concurrency=concurrency,
        total_requests=num_samples,
        successful=sum(1 for r in results if r.success),
        failed=sum(1 for r in results if not r.success),
        wall_time_sec=wall_time,
        max_tokens=max_tokens,
    )
    for r in results:
        if r.success:
            bench.latencies_ms.append(r.latency_ms)
            bench.ttfts_ms.append(r.ttft_ms)
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

def print_header(ollama_version: str | None, model: str, max_tokens: int, samples: int):
    print()
    print("=" * 95)
    print("  HAYABUSA vs OLLAMA v0.19+ ガチ勝負ベンチマーク")
    print(f"  Ollama version: {ollama_version or 'unknown'}")
    print(f"  Model: {model}  |  max_tokens={max_tokens}  |  samples={samples}")
    print(f"  Date: {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 95)
    print()


def print_result_table(results: list[BenchResult]):
    print()
    header = (
        f"{'Target':<12} {'Conc':>4} {'OK':>4} "
        f"{'TTFT':>7} {'TTFT95':>7} "
        f"{'Avg(ms)':>8} {'P95(ms)':>8} "
        f"{'tok/s':>7} {'dec t/s':>8} {'req/s':>6}"
    )
    print(header)
    print("-" * len(header))

    for r in results:
        print(
            f"{r.target:<12} {r.concurrency:>4} {r.successful:>4} "
            f"{r.avg_ttft:>7.0f} {r.p95_ttft:>7.0f} "
            f"{r.avg_latency:>8.0f} {r.p95:>8.0f} "
            f"{r.tok_per_sec:>7.1f} {r.decode_tok_per_sec:>8.1f} {r.req_per_sec:>6.2f}"
        )

    print()


def print_versus(results: list[BenchResult]):
    by_target: dict[str, dict[int, BenchResult]] = {}
    for r in results:
        by_target.setdefault(r.target, {})[r.concurrency] = r

    hayabusa = by_target.get("Hayabusa", {})
    ollama = by_target.get("Ollama", {})

    if not hayabusa or not ollama:
        return

    print("┌────────────────────────────────────────────────────────────────────────────┐")
    print("│                    HAYABUSA vs OLLAMA  直接対決                             │")
    print("├──────┬─────────────────────┬─────────────────────┬─────────────────────────┤")
    print("│ Conc │     Hayabusa        │      Ollama         │       勝敗              │")
    print("│      │ tok/s  TTFT  Avg    │ tok/s  TTFT  Avg    │ tok/s  TTFT  Latency    │")
    print("├──────┼─────────────────────┼─────────────────────┼─────────────────────────┤")

    concurrencies = sorted(set(list(hayabusa.keys()) + list(ollama.keys())))
    hayabusa_wins = 0
    ollama_wins = 0

    for c in concurrencies:
        h = hayabusa.get(c)
        o = ollama.get(c)
        if not h or not o:
            continue

        tok_ratio = h.tok_per_sec / o.tok_per_sec if o.tok_per_sec > 0 else float("inf")
        ttft_ratio = o.avg_ttft / h.avg_ttft if h.avg_ttft > 0 else 0
        lat_ratio = o.avg_latency / h.avg_latency if h.avg_latency > 0 else 0

        tok_winner = "H" if tok_ratio > 1.05 else ("O" if tok_ratio < 0.95 else "=")
        ttft_winner = "H" if ttft_ratio > 1.05 else ("O" if ttft_ratio < 0.95 else "=")
        lat_winner = "H" if lat_ratio > 1.05 else ("O" if lat_ratio < 0.95 else "=")

        for w in [tok_winner, ttft_winner, lat_winner]:
            if w == "H":
                hayabusa_wins += 1
            elif w == "O":
                ollama_wins += 1

        def fmt_win(label, ratio):
            if label == "H":
                return f"H {ratio:.2f}x"
            elif label == "O":
                return f"O {1/ratio:.2f}x"
            else:
                return " DRAW  "

        print(
            f"│ {c:>4} │ {h.tok_per_sec:>5.1f} {h.avg_ttft:>5.0f} {h.avg_latency:>5.0f}  │"
            f" {o.tok_per_sec:>5.1f} {o.avg_ttft:>5.0f} {o.avg_latency:>5.0f}  │"
            f" {fmt_win(tok_winner, tok_ratio):>7s}"
            f" {fmt_win(ttft_winner, ttft_ratio):>7s}"
            f" {fmt_win(lat_winner, lat_ratio):>7s}   │"
        )

    print("├──────┴─────────────────────┴─────────────────────┴─────────────────────────┤")

    total = hayabusa_wins + ollama_wins
    if hayabusa_wins > ollama_wins:
        verdict = f"HAYABUSA WIN  ({hayabusa_wins}/{total} categories)"
    elif ollama_wins > hayabusa_wins:
        verdict = f"OLLAMA WIN  ({ollama_wins}/{total} categories)"
    else:
        verdict = "DRAW"
    print(f"│  VERDICT: {verdict:<67s} │")
    print("└────────────────────────────────────────────────────────────────────────────┘")
    print()


def save_results(
    results: list[BenchResult],
    ollama_version: str | None,
    model: str,
    hayabusa_model: str,
    max_tokens: int,
):
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
            "avg_ttft_ms": round(r.avg_ttft, 1),
            "p50_ttft_ms": round(r.p50_ttft, 1),
            "p95_ttft_ms": round(r.p95_ttft, 1),
            "tok_per_sec": round(r.tok_per_sec, 2),
            "decode_tok_per_sec": round(r.decode_tok_per_sec, 2),
            "req_per_sec": round(r.req_per_sec, 3),
            "total_prompt_tokens": r.total_prompt_tokens,
            "total_completion_tokens": r.total_completion_tokens,
        })

    out = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "config": {
            "ollama_version": ollama_version,
            "ollama_model": model,
            "hayabusa_model": hayabusa_model,
            "max_tokens": max_tokens,
            "prompts_count": len(PROMPTS),
        },
        "results": data,
    }

    with open(OUTPUT_PATH, "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
    print(f"Results saved to {OUTPUT_PATH}")


# ── Main ────────────────────────────────────────────────────────────

async def main_async(args):
    concurrencies = args.concurrency
    num_samples = args.samples
    max_tokens = args.max_tokens

    hayabusa_base = HAYABUSA_BASE.format(port=args.hayabusa_port)
    hayabusa_url = f"{hayabusa_base}/v1/chat/completions"
    ollama_url = f"{OLLAMA_BASE}/v1/chat/completions"

    # Check servers
    targets_to_check = []
    if "hayabusa" in args.target:
        targets_to_check.append(("Hayabusa", hayabusa_base))
    if "ollama" in args.target:
        targets_to_check.append(("Ollama", OLLAMA_BASE))

    available_targets = []
    ollama_version = None

    for name, base in targets_to_check:
        sys.stderr.write(f"Checking {name} at {base}... ")
        sys.stderr.flush()
        ok = await check_server(base, name)
        if ok:
            sys.stderr.write("OK\n")
            if name == "Hayabusa":
                available_targets.append(("Hayabusa", hayabusa_url, args.hayabusa_model))
            else:
                ollama_version = await get_ollama_version()
                sys.stderr.write(f"  Ollama version: {ollama_version}\n")
                available_targets.append(("Ollama", ollama_url, args.model))
        else:
            sys.stderr.write("UNAVAILABLE\n")

    if not available_targets:
        print("\nNo servers available.")
        print("\nStart servers first:")
        print(f"  # Hayabusa:")
        print(f"  .build/debug/Hayabusa {args.hayabusa_model} --backend mlx")
        print(f"  # Ollama (v0.19+ with MLX):")
        print(f"  ollama serve && ollama pull {args.model}")
        sys.exit(1)

    print_header(ollama_version, args.model, max_tokens, num_samples)

    all_results: list[BenchResult] = []

    # SSE streaming on /v1/chat/completions is not implemented on Hayabusa main yet
    # (see Roadmap). Force non-streaming so the TTFT figures don't silently fall back
    # to the "non-streaming = full-response latency" path on Hayabusa while Ollama
    # genuinely streams. Re-enable via --use-streaming once SSE lands.
    use_streaming = bool(getattr(args, "use_streaming", False))
    for conc in concurrencies:
        for name, url, model in available_targets:
            print(f"--- {name} (concurrency={conc}) ---")
            result = await run_bench(
                url, model, name, conc, num_samples,
                max_tokens, use_streaming=use_streaming,
            )
            all_results.append(result)
            print(
                f"  => TTFT={result.avg_ttft:.0f}ms  avg={result.avg_latency:.0f}ms  "
                f"tok/s={result.tok_per_sec:.1f}  "
                f"({result.successful}/{result.total_requests} ok)"
            )
            print()

    print_result_table(all_results)
    print_versus(all_results)
    save_results(all_results, ollama_version, args.model, args.hayabusa_model, max_tokens)


def main():
    parser = argparse.ArgumentParser(
        description="Hayabusa vs Ollama v0.19+ ガチ勝負ベンチマーク",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--target", nargs="+", default=["hayabusa", "ollama"],
        choices=["hayabusa", "ollama"],
        help="Targets to benchmark (default: both)",
    )
    parser.add_argument(
        "--model", default="qwen3.5:latest",
        help="Ollama model name (default: qwen3.5:latest)",
    )
    parser.add_argument(
        "--hayabusa-model", default="mlx-community/Qwen3.5-9B-MLX-4bit",
        help="Hayabusa model ID (default: mlx-community/Qwen3.5-9B-MLX-4bit)",
    )
    parser.add_argument(
        "--concurrency", nargs="+", type=int, default=[1, 2, 4, 8, 16],
        help="Concurrency levels (default: 1 2 4 8 16)",
    )
    parser.add_argument(
        "--samples", type=int, default=30,
        help="Requests per concurrency level (default: 30)",
    )
    parser.add_argument(
        "--max-tokens", type=int, default=128,
        help="Max tokens per request (default: 128)",
    )
    parser.add_argument(
        "--hayabusa-port", type=int, default=8080,
        help="Hayabusa port (default: 8080)",
    )
    parser.add_argument(
        "--use-streaming", action="store_true",
        help=(
            "Use SSE streaming endpoints. Default off because Hayabusa's "
            "/v1/chat/completions does not implement SSE on main; enabling this "
            "before the SSE roadmap item lands will mis-report TTFT."
        ),
    )
    args = parser.parse_args()
    asyncio.run(main_async(args))


if __name__ == "__main__":
    main()
