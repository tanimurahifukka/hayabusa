#!/usr/bin/env python3
"""Hayabusa Layer Skip Benchmark — Qwen3.5-9B, Thinking OFF mode.

Disables Qwen3.5 thinking mode to measure layer skip quality on direct output.
- Ollama: think=false in request
- MLX: enable_thinking=False in chat template

Compares:
  1. Ollama qwen3.5:9b baseline (no think)
  2. MLX baseline (no think, all 32 layers)
  3. MLX skip-sweet (no think, 11/32 layers)

Usage:
    /tmp/mlx_env/bin/python3.13 scripts/bench_layer_skip_nothink.py
"""

from __future__ import annotations

import asyncio
import json
import os
import resource
import statistics
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import aiohttp

# ── Config ────────────────────────────────────────────────────────

MLX_MODEL = "mlx-community/Qwen3.5-9B-MLX-4bit"
OLLAMA_MODEL = "qwen3.5:9b"
OLLAMA_PORT = 11434

MAX_TOKENS = 512
TEMPERATURE = 0.0
NUM_SAMPLES = 10
CONCURRENCIES = [1, 4, 8]

SCRIPT_DIR = Path(__file__).resolve().parent
OUTPUT_PATH = SCRIPT_DIR / "bench_layer_skip_nothink.json"

# Sweet spot for no-think mode (BERTScore F1 >= 0.84 vs Ollama)
# Much more conservative than thinking mode (11 layers → 2 layers)
SWEET_SPOT_INDICES = {4, 8}  # 2 layers (least important: layer 4=0.0705, layer 8=0.0782)
SWEET_SPOT_THRESHOLD = 0.0782

SYSTEM_PROMPT = "You are a medical professional. Write detailed SOAP notes."

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
class ConcurrencyResult:
    concurrency: int
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
    def p95_latency_ms(self) -> float:
        lats = sorted([r.latency_ms for r in self.results if r.success])
        if not lats:
            return 0
        idx = int(len(lats) * 0.95)
        return lats[min(idx, len(lats) - 1)]

    @property
    def total_completion_tokens(self) -> int:
        return sum(r.completion_tokens for r in self.results if r.success)

    @property
    def texts(self) -> list[str]:
        return [r.response_text for r in self.results if r.success and r.response_text]


# ── Ollama API (think=false) ─────────────────────────────────────

async def call_ollama(session: aiohttp.ClientSession, prompt: str) -> RequestResult:
    url = f"http://localhost:{OLLAMA_PORT}/api/chat"
    payload = {
        "model": OLLAMA_MODEL,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
        "think": False,
        "stream": False,
        "options": {"num_predict": MAX_TOKENS, "temperature": TEMPERATURE},
    }
    t0 = time.perf_counter()
    try:
        async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=600)) as resp:
            data = await resp.json()
            elapsed_ms = (time.perf_counter() - t0) * 1000
            content = data.get("message", {}).get("content", "")
            pt = data.get("prompt_eval_count", 0)
            ct = data.get("eval_count", 0)
            tps = ct / (elapsed_ms / 1000) if elapsed_ms > 0 else 0
            return RequestResult(elapsed_ms, pt, ct, tps, True, content)
    except Exception as e:
        elapsed_ms = (time.perf_counter() - t0) * 1000
        return RequestResult(elapsed_ms, 0, 0, 0, False, error=str(e))


def get_ollama_rss() -> int:
    try:
        result = subprocess.run(["pgrep", "-f", "ollama serve"], capture_output=True, text=True)
        pids = result.stdout.strip().split('\n')
        total = 0
        for pid in pids:
            if pid.strip():
                ps = subprocess.run(["ps", "-o", "rss=", "-p", pid.strip()], capture_output=True, text=True)
                rss_kb = ps.stdout.strip()
                if rss_kb:
                    total += int(rss_kb) * 1024
        return total
    except Exception:
        return 0


# ── MLX direct inference (enable_thinking=False) ─────────────────

_mlx_model = None
_mlx_tokenizer = None
_mlx_sampler = None
_skip_set: set[int] = set()
_original_call = None


def _load_mlx_model():
    global _mlx_model, _mlx_tokenizer, _mlx_sampler
    if _mlx_model is not None:
        return
    import mlx_lm
    from mlx_lm.sample_utils import make_sampler
    print("  Loading MLX model...")
    _mlx_model, _mlx_tokenizer = mlx_lm.load(MLX_MODEL)
    _mlx_sampler = make_sampler(temp=TEMPERATURE)
    result = mlx_lm.generate(_mlx_model, _mlx_tokenizer, prompt="Hello", max_tokens=5, sampler=_mlx_sampler, verbose=False)
    print(f"  Model loaded and warmed up.")


def _apply_layer_skip(skip_indices: set[int]):
    global _skip_set, _original_call

    import mlx.core as mx
    import mlx_lm.models.qwen3_5 as q35_mod

    Qwen3_5TextModel = q35_mod.Qwen3_5TextModel
    _skip_set = skip_indices

    if _original_call is None:
        _original_call = Qwen3_5TextModel.__call__

    if not skip_indices:
        Qwen3_5TextModel.__call__ = _original_call
        return

    create_mask = q35_mod.create_attention_mask
    create_ssm = q35_mod.create_ssm_mask

    def _patched_call(self, inputs, cache=None, input_embeddings=None):
        if input_embeddings is not None:
            h = input_embeddings
        else:
            h = self.embed_tokens(inputs)

        if cache is None:
            cache = [None] * len(self.layers)

        fa_mask = create_mask(h, cache[self.fa_idx])
        ssm_mask = create_ssm(h, cache[self.ssm_idx])

        is_generation = h.shape[1] == 1

        for i, (layer, c) in enumerate(zip(self.layers, cache)):
            if is_generation and i in _skip_set:
                continue
            mask = ssm_mask if layer.is_linear else fa_mask
            h = layer(h, mask=mask, cache=c)

        return self.norm(h)

    Qwen3_5TextModel.__call__ = _patched_call
    print(f"  Applied true layer skip for {len(skip_indices)} layers: {sorted(skip_indices)}")


def _restore_original():
    global _original_call
    if _original_call is not None:
        import mlx_lm.models.qwen3_5 as q35_mod
        q35_mod.Qwen3_5TextModel.__call__ = _original_call


def _mlx_generate(prompt: str) -> RequestResult:
    import mlx_lm

    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": prompt},
    ]
    # enable_thinking=False → inserts <think>\n\n</think>\n\n to skip thinking
    chat_prompt = _mlx_tokenizer.apply_chat_template(
        messages, tokenize=False, add_generation_prompt=True, enable_thinking=False
    )
    prompt_tokens = _mlx_tokenizer.encode(chat_prompt)
    pt_count = len(prompt_tokens)

    t0 = time.perf_counter()
    try:
        response = mlx_lm.generate(
            _mlx_model,
            _mlx_tokenizer,
            prompt=chat_prompt,
            max_tokens=MAX_TOKENS,
            sampler=_mlx_sampler,
            verbose=False,
        )
        elapsed_ms = (time.perf_counter() - t0) * 1000
        ct = len(_mlx_tokenizer.encode(response))
        tps = ct / (elapsed_ms / 1000) if elapsed_ms > 0 else 0
        return RequestResult(elapsed_ms, pt_count, ct, tps, True, response)
    except Exception as e:
        elapsed_ms = (time.perf_counter() - t0) * 1000
        return RequestResult(elapsed_ms, pt_count, 0, 0, False, error=str(e))


def get_process_rss_mb() -> int:
    try:
        rss_bytes = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        if sys.platform == "darwin":
            return rss_bytes // (1024 * 1024)
        return rss_bytes // 1024
    except Exception:
        return 0


# ── Benchmark runners ─────────────────────────────────────────────

async def run_ollama_bench(concurrency: int) -> ConcurrencyResult:
    cr = ConcurrencyResult(concurrency=concurrency)
    prompts = BENCH_PROMPTS[:NUM_SAMPLES]

    async with aiohttp.ClientSession() as session:
        await call_ollama(session, "Say hi.")

    async with aiohttp.ClientSession() as session:
        for batch_start in range(0, len(prompts), concurrency):
            batch = prompts[batch_start:batch_start + concurrency]
            tasks = [call_ollama(session, p) for p in batch]
            results = await asyncio.gather(*tasks)
            cr.results.extend(results)
            ok = sum(1 for r in results if r.success)
            sys.stderr.write(f"\r  [Ollama] c={concurrency} batch {batch_start//concurrency+1}: {ok}/{len(batch)} ok")
            sys.stderr.flush()

    sys.stderr.write(
        f"\r  [Ollama] c={concurrency}: {cr.successful}/{len(prompts)} ok, "
        f"avg={cr.avg_tok_per_sec:.1f} tok/s, p95={cr.p95_latency_ms:.0f}ms\n"
    )
    return cr


def run_mlx_bench(config_name: str, skip_indices: set[int]) -> ConcurrencyResult:
    cr = ConcurrencyResult(concurrency=1)
    prompts = BENCH_PROMPTS[:NUM_SAMPLES]

    _load_mlx_model()
    _apply_layer_skip(skip_indices)

    # Warmup (no-think mode)
    _mlx_generate("Say hi.")

    for i, prompt in enumerate(prompts):
        result = _mlx_generate(prompt)
        cr.results.append(result)
        sys.stderr.write(
            f"\r  [{config_name}] {i+1}/{len(prompts)}: "
            f"{result.tok_per_sec:.1f} tok/s, {result.completion_tokens} tok"
        )
        sys.stderr.flush()

    sys.stderr.write(
        f"\r  [{config_name}]: {cr.successful}/{len(prompts)} ok, "
        f"avg={cr.avg_tok_per_sec:.1f} tok/s, p95={cr.p95_latency_ms:.0f}ms\n"
    )
    return cr


# ── BERTScore ────────────────────────────────────────────────────

def compute_bertscore(references: list[str], candidates: list[str]) -> dict | None:
    try:
        from bert_score import score as bert_score
    except ImportError:
        sys.stderr.write("  WARNING: bert-score not installed, skipping\n")
        return None
    if not references or not candidates:
        return None
    n = min(len(references), len(candidates))
    sys.stderr.write(f"  Computing BERTScore for {n} pairs...\n")
    P, R, F1 = bert_score(candidates[:n], references[:n], lang="en", verbose=False)
    return {
        "precision": round(P.mean().item(), 4),
        "recall": round(R.mean().item(), 4),
        "f1": round(F1.mean().item(), 4),
        "num_pairs": n,
    }


# ── Display ──────────────────────────────────────────────────────

def print_table(all_data: list[dict]):
    print()
    print("=" * 100)
    print("  Table 3: Qwen3.5-9B Layer Skip — Thinking OFF (SOAP Generation)")
    print("  max_tokens=512, temperature=0.0, 10 SOAP prompts, enable_thinking=False")
    print("=" * 100)

    for conc in CONCURRENCIES:
        # Check if any data has this concurrency
        has_data = False
        for d in all_data:
            for cr in d["concurrency_results"]:
                if cr["concurrency"] == conc:
                    has_data = True
                    break
        if not has_data:
            continue

        print(f"\n  Concurrency = {conc}")
        print("  ┌──────────────────────────┬────────┬─────────┬──────────┬──────────┬────────────┬────────┐")
        print("  │ Config                   │ tok/s  │ Speedup │ Avg (ms) │ P95 (ms) │ BERTScore  │ RSS MB │")
        print("  ├──────────────────────────┼────────┼─────────┼──────────┼──────────┼────────────┼────────┤")

        mlx_baseline_tps = None
        for d in all_data:
            if d["name"] == "MLX baseline":
                for cr in d["concurrency_results"]:
                    if cr["concurrency"] == 1:
                        mlx_baseline_tps = cr["avg_tok_per_sec"]

        for d in all_data:
            for cr in d["concurrency_results"]:
                if cr["concurrency"] != conc:
                    continue
                name = d["name"][:24]
                tps = cr["avg_tok_per_sec"]
                if d["backend"] == "ollama":
                    ref = None
                    for od in all_data:
                        if od["name"] == "Ollama baseline":
                            for ocr in od["concurrency_results"]:
                                if ocr["concurrency"] == 1:
                                    ref = ocr["avg_tok_per_sec"]
                    speedup = tps / ref if ref and ref > 0 else 0
                else:
                    speedup = tps / mlx_baseline_tps if mlx_baseline_tps and mlx_baseline_tps > 0 else 0
                avg_ms = cr["avg_latency_ms"]
                p95_ms = cr["p95_latency_ms"]
                bs = d.get("bertscore", {})
                is_baseline = d["name"] in ("Ollama baseline", "MLX baseline")
                bs_str = f"{bs['f1']:.4f}" if bs and "f1" in bs else "baseline" if is_baseline else "—"
                rss = d.get("rss_mb", "—")
                rss_str = f"{rss}" if isinstance(rss, (int, float)) else str(rss)
                print(f"  │ {name:<24} │ {tps:6.1f} │ {speedup:6.2f}x │ {avg_ms:8.0f} │ {p95_ms:8.0f} │ {bs_str:>10} │ {rss_str:>6} │")

        print("  └──────────────────────────┴────────┴─────────┴──────────┴──────────┴────────────┴────────┘")


# ── Main ──────────────────────────────────────────────────────────

async def main():
    print()
    print("=" * 70)
    print("  Hayabusa Layer Skip Benchmark — Qwen3.5-9B (Thinking OFF)")
    print(f"  MLX model: {MLX_MODEL}")
    print(f"  Ollama model: {OLLAMA_MODEL}")
    print(f"  Samples: {NUM_SAMPLES} | Max tokens: {MAX_TOKENS}")
    print(f"  Thinking: OFF (enable_thinking=False / think=false)")
    print(f"  Sweet spot: {len(SWEET_SPOT_INDICES)}/32 layers")
    print("=" * 70)

    all_data: list[dict] = []
    ollama_texts: list[str] = []

    # ── 1. Ollama baseline (no think) ─────────────────────────────
    print(f"\n{'━' * 55}")
    print(f"  Ollama baseline (think=false): {OLLAMA_MODEL}")
    print(f"{'━' * 55}")

    try:
        async with aiohttp.ClientSession() as s:
            async with s.get(f"http://localhost:{OLLAMA_PORT}/api/tags",
                             timeout=aiohttp.ClientTimeout(total=5)) as resp:
                if resp.status == 200:
                    print("  Ollama running")
    except Exception:
        print("  ERROR: Ollama not reachable")
        return

    print("  Warming up...")
    async with aiohttp.ClientSession() as s:
        await call_ollama(s, "Say hello.")

    ollama_rss = round(get_ollama_rss() / 1024 / 1024)

    ollama_crs = []
    for conc in CONCURRENCIES:
        cr = await run_ollama_bench(conc)
        ollama_crs.append({
            "concurrency": conc,
            "successful": cr.successful,
            "avg_tok_per_sec": round(cr.avg_tok_per_sec, 1),
            "median_tok_per_sec": round(cr.median_tok_per_sec, 1),
            "avg_latency_ms": round(cr.avg_latency_ms, 0),
            "p95_latency_ms": round(cr.p95_latency_ms, 0),
            "total_completion_tokens": cr.total_completion_tokens,
        })
        if conc == 1:
            ollama_texts = cr.texts

    all_data.append({
        "name": "Ollama baseline",
        "description": f"Ollama {OLLAMA_MODEL} (think=false)",
        "backend": "ollama",
        "skip_count": 0,
        "skip_indices": [],
        "concurrency_results": ollama_crs,
        "rss_mb": ollama_rss,
        "texts_c1": ollama_texts[:NUM_SAMPLES],
    })

    # ── 2. MLX baseline (no think, no skip) ───────────────────────
    print(f"\n{'━' * 55}")
    print(f"  MLX baseline (no think): all 32 layers")
    print(f"{'━' * 55}")

    cr = run_mlx_bench("MLX baseline", set())
    mlx_baseline_texts = cr.texts
    mlx_rss = get_process_rss_mb()

    all_data.append({
        "name": "MLX baseline",
        "description": "MLX no skip, no think (all 32 layers)",
        "backend": "mlx",
        "skip_count": 0,
        "skip_indices": [],
        "concurrency_results": [{
            "concurrency": 1,
            "successful": cr.successful,
            "avg_tok_per_sec": round(cr.avg_tok_per_sec, 1),
            "median_tok_per_sec": round(cr.median_tok_per_sec, 1),
            "avg_latency_ms": round(cr.avg_latency_ms, 0),
            "p95_latency_ms": round(cr.p95_latency_ms, 0),
            "total_completion_tokens": cr.total_completion_tokens,
        }],
        "rss_mb": mlx_rss,
        "texts_c1": mlx_baseline_texts[:NUM_SAMPLES],
    })

    # ── 3. MLX skip-sweet (no think) ──────────────────────────────
    print(f"\n{'━' * 55}")
    print(f"  MLX skip-sweet (no think): {len(SWEET_SPOT_INDICES)}/32 layers")
    print(f"{'━' * 55}")

    cr = run_mlx_bench("MLX skip-sweet", SWEET_SPOT_INDICES)
    sweet_texts = cr.texts

    all_data.append({
        "name": "MLX skip-sweet",
        "description": f"MLX true skip {len(SWEET_SPOT_INDICES)}/32, no think",
        "backend": "mlx",
        "skip_count": len(SWEET_SPOT_INDICES),
        "skip_indices": sorted(SWEET_SPOT_INDICES),
        "threshold": SWEET_SPOT_THRESHOLD,
        "concurrency_results": [{
            "concurrency": 1,
            "successful": cr.successful,
            "avg_tok_per_sec": round(cr.avg_tok_per_sec, 1),
            "median_tok_per_sec": round(cr.median_tok_per_sec, 1),
            "avg_latency_ms": round(cr.avg_latency_ms, 0),
            "p95_latency_ms": round(cr.p95_latency_ms, 0),
            "total_completion_tokens": cr.total_completion_tokens,
        }],
        "rss_mb": mlx_rss,
        "texts_c1": sweet_texts[:NUM_SAMPLES],
    })

    _restore_original()

    # ── BERTScore ─────────────────────────────────────────────────
    print(f"\n{'━' * 55}")
    print("  Computing BERTScore (vs Ollama baseline)...")
    print(f"{'━' * 55}")

    for entry in all_data:
        if entry["name"] == "Ollama baseline":
            entry["bertscore"] = None
            continue
        texts = entry.get("texts_c1", [])
        if ollama_texts and texts:
            n = min(len(ollama_texts), len(texts))
            entry["bertscore"] = compute_bertscore(ollama_texts[:n], texts[:n])
        else:
            entry["bertscore"] = None

    # ── Print Table ───────────────────────────────────────────────
    print_table(all_data)

    # Sample outputs
    print(f"\n  Sample Outputs (prompt 1):")
    for entry in all_data:
        texts = entry.get("texts_c1", [])
        if texts:
            sample = texts[0][:200].replace('\n', ' ')
            print(f"  [{entry['name']}] {sample}...")

    # BERTScore summary
    skip_bs = None
    for entry in all_data:
        if entry["name"] == "MLX skip-sweet" and entry.get("bertscore"):
            skip_bs = entry["bertscore"]["f1"]

    print(f"\n  Quality Check:")
    if skip_bs is not None:
        status = "PASS" if skip_bs >= 0.84 else "FAIL"
        print(f"  ├─ MLX skip-sweet BERTScore F1: {skip_bs:.4f} [{status}] (target ≥ 0.84)")
    print(f"  ├─ Sweet spot (no-think): {len(SWEET_SPOT_INDICES)}/32 layers (threshold ≤ {SWEET_SPOT_THRESHOLD})")
    print(f"  ├─ Skipped layers: {sorted(SWEET_SPOT_INDICES)}")
    print(f"  └─ Note: thinking mode tolerates 11/32, no-think only 2/32")

    # ── Save ──────────────────────────────────────────────────────
    output = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "method": "true_layer_skip (generation-phase only)",
        "thinking": False,
        "config": {
            "mlx_model": MLX_MODEL,
            "ollama_model": OLLAMA_MODEL,
            "num_layers": 32,
            "max_tokens": MAX_TOKENS,
            "temperature": TEMPERATURE,
            "num_samples": NUM_SAMPLES,
            "thinking_mode": "OFF (enable_thinking=False / think=false)",
        },
        "sweet_spot": {
            "layers_skipped": len(SWEET_SPOT_INDICES),
            "threshold": SWEET_SPOT_THRESHOLD,
            "skipped_indices": sorted(SWEET_SPOT_INDICES),
        },
        "results": [{k: v for k, v in d.items() if k != "texts_c1"} for d in all_data],
        "sample_outputs": {
            entry["name"]: entry.get("texts_c1", [""])[0][:500]
            for entry in all_data if entry.get("texts_c1")
        },
    }

    with open(OUTPUT_PATH, "w") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    print(f"\n  Results saved to {OUTPUT_PATH}")


if __name__ == "__main__":
    asyncio.run(main())
