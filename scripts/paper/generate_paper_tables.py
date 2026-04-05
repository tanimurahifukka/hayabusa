#!/usr/bin/env python3
"""KAJIBA Paper Table Generator — 実験結果からMarkdown/LaTeXテーブルを生成.

実験結果JSONファイルを読み込み、論文用のテーブルを生成する。

Usage:
    python scripts/paper/generate_paper_tables.py
    python scripts/paper/generate_paper_tables.py --format both
    python scripts/paper/generate_paper_tables.py --results-dir ./scripts/paper/results --format tex
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
SCRIPTS_DIR = SCRIPT_DIR.parent
RESULTS_DIR = SCRIPT_DIR / "results"


# ── JSONファイル読み込みヘルパー ──────────────────────────────────────

def load_json(path: Path) -> dict | None:
    """JSONファイルを読み込む。存在しなければNone。"""
    if not path.exists():
        print(f"  WARNING: {path} not found, skipping.", file=sys.stderr)
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as e:
        print(f"  WARNING: Failed to read {path}: {e}", file=sys.stderr)
        return None


def find_latest_result(results_dir: Path, prefix: str) -> dict | None:
    """指定プレフィックスの最新結果ファイルを読み込む。"""
    candidates = sorted(results_dir.glob(f"{prefix}*.json"), reverse=True)
    if not candidates:
        print(f"  WARNING: No {prefix}*.json found in {results_dir}", file=sys.stderr)
        return None
    return load_json(candidates[0])


# ── Table 1: Hayabusa vs Ollama ──────────────────────────────────────

def generate_table1(data: dict | None) -> tuple[str, str]:
    """Table 1: Hayabusa vs Ollama 性能比較."""
    md_lines = ["## Table 1: Hayabusa vs Ollama Performance Comparison", ""]
    tex_lines = [
        r"\begin{table}[h]",
        r"\centering",
        r"\caption{Hayabusa vs Ollama Performance Comparison}",
        r"\label{tab:hayabusa-vs-ollama}",
        r"\begin{tabular}{lrrrrrr}",
        r"\toprule",
        r"Target & Conc. & Avg (ms) & P95 (ms) & TTFT (ms) & tok/s & req/s \\",
        r"\midrule",
    ]
    md_lines.append("| Target | Conc. | Avg (ms) | P95 (ms) | TTFT (ms) | tok/s | req/s |")
    md_lines.append("|--------|-------|----------|----------|-----------|-------|-------|")

    if data and "results" in data:
        for r in data["results"]:
            target = r.get("target", r.get("name", "?"))
            conc = r.get("concurrency", "?")
            avg = r.get("avg_latency_ms", r.get("avg_latency", 0))
            p95 = r.get("p95_latency_ms", r.get("p95", 0))
            ttft = r.get("avg_ttft_ms", r.get("avg_ttft", 0))
            tps = r.get("throughput_tok_s", r.get("tok_per_sec", 0))
            rps = r.get("req_per_sec", 0)

            md_lines.append(f"| {target} | {conc} | {avg:.0f} | {p95:.0f} | {ttft:.0f} | {tps:.1f} | {rps:.2f} |")
            tex_lines.append(f"{target} & {conc} & {avg:.0f} & {p95:.0f} & {ttft:.0f} & {tps:.1f} & {rps:.2f} \\\\")
    else:
        md_lines.append("| (no data) | - | - | - | - | - | - |")
        tex_lines.append(r"(no data) & - & - & - & - & - & - \\")

    tex_lines.extend([r"\bottomrule", r"\end{tabular}", r"\end{table}", ""])
    md_lines.append("")

    return "\n".join(md_lines), "\n".join(tex_lines)


# ── Table 2: MLX vs llama.cpp Memory ─────────────────────────────────

def generate_table2(data: dict | None) -> tuple[str, str]:
    """Table 2: MLX vs llama.cpp メモリ使用量比較."""
    md_lines = ["## Table 2: MLX vs llama.cpp Memory Usage", ""]
    tex_lines = [
        r"\begin{table}[h]",
        r"\centering",
        r"\caption{MLX vs llama.cpp Memory Usage}",
        r"\label{tab:memory}",
        r"\begin{tabular}{lrrrr}",
        r"\toprule",
        r"Backend & Model Size & RSS (MB) & tok/s & TTFT (ms) \\",
        r"\midrule",
    ]
    md_lines.append("| Backend | Model Size | RSS (MB) | tok/s | TTFT (ms) |")
    md_lines.append("|---------|-----------|----------|-------|-----------|")

    if data and "results" in data:
        for r in data["results"]:
            backend = r.get("backend", r.get("name", "?"))
            model_size = r.get("model_size", r.get("model", "?"))
            rss = r.get("rss_mb", r.get("memory_mb", 0))
            tps = r.get("tok_per_sec", r.get("throughput_tok_s", 0))
            ttft = r.get("ttft_ms", r.get("avg_ttft_ms", 0))

            md_lines.append(f"| {backend} | {model_size} | {rss:.0f} | {tps:.1f} | {ttft:.0f} |")
            tex_lines.append(f"{backend} & {model_size} & {rss:.0f} & {tps:.1f} & {ttft:.0f} \\\\")
    else:
        md_lines.append("| (no data) | - | - | - | - |")
        tex_lines.append(r"(no data) & - & - & - & - \\")

    tex_lines.extend([r"\bottomrule", r"\end{tabular}", r"\end{table}", ""])
    md_lines.append("")

    return "\n".join(md_lines), "\n".join(tex_lines)


# ── Table 3: Uzu Cluster ─────────────────────────────────────────────

def generate_table3(data: dict | None) -> tuple[str, str]:
    """Table 3: Uzu Cluster スケーリング性能."""
    md_lines = ["## Table 3: Uzu Cluster Scaling Performance", ""]
    tex_lines = [
        r"\begin{table}[h]",
        r"\centering",
        r"\caption{Uzu Cluster Scaling Performance}",
        r"\label{tab:uzu-cluster}",
        r"\begin{tabular}{llrrrrr}",
        r"\toprule",
        r"Target & Conc. & Avg (ms) & P50 (ms) & P95 (ms) & tok/s & req/s \\",
        r"\midrule",
    ]
    md_lines.append("| Target | Conc. | Avg (ms) | P50 (ms) | P95 (ms) | tok/s | req/s |")
    md_lines.append("|--------|-------|----------|----------|----------|-------|-------|")

    if data and "conditions" in data:
        for r in data["conditions"]:
            target = r.get("target", "?")
            conc = r.get("concurrency", "?")
            avg = r.get("avg_latency_ms", 0)
            p50 = r.get("p50_latency_ms", 0)
            p95 = r.get("p95_latency_ms", 0)
            tps = r.get("throughput_tok_s", 0)
            rps = r.get("req_per_sec", 0)

            md_lines.append(f"| {target} | {conc} | {avg:.0f} | {p50:.0f} | {p95:.0f} | {tps:.1f} | {rps:.2f} |")
            tex_lines.append(f"{target} & {conc} & {avg:.0f} & {p50:.0f} & {p95:.0f} & {tps:.1f} & {rps:.2f} \\\\")
    else:
        md_lines.append("| (no data) | - | - | - | - | - | - |")
        tex_lines.append(r"(no data) & - & - & - & - & - & - \\")

    tex_lines.extend([r"\bottomrule", r"\end{tabular}", r"\end{table}", ""])
    md_lines.append("")

    return "\n".join(md_lines), "\n".join(tex_lines)


# ── Table 4: Specialist vs Generalist ─────────────────────────────────

def generate_table4(results_dir: Path) -> tuple[str, str]:
    """Table 4: Specialist vs Generalist 精度比較."""
    md_lines = ["## Table 4: Specialist vs Generalist Accuracy", ""]
    tex_lines = [
        r"\begin{table}[h]",
        r"\centering",
        r"\caption{Specialist vs Generalist Accuracy}",
        r"\label{tab:specialist}",
        r"\begin{tabular}{lrrrr}",
        r"\toprule",
        r"Domain & Specialist Avg & Generalist Avg & Spec. Win & Tie \\",
        r"\midrule",
    ]
    md_lines.append("| Domain | Specialist Avg | Generalist Avg | Spec. Win Rate | Tie Rate |")
    md_lines.append("|--------|---------------|----------------|----------------|----------|")

    has_data = False
    for domain in ["stripe", "supabase", "orca"]:
        data = find_latest_result(results_dir, f"exp_b_specialist_{domain}")
        if data and "summary" in data:
            has_data = True
            s = data["summary"]
            spec_avg = s.get("specialist", {}).get("avg_score", 0)
            gen_avg = s.get("generalist", {}).get("avg_score", 0)
            spec_win = s.get("specialist_win_rate", 0)
            tie = s.get("tie_rate", 0)

            md_lines.append(f"| {domain} | {spec_avg:.1%} | {gen_avg:.1%} | {spec_win:.1%} | {tie:.1%} |")
            tex_lines.append(f"{domain} & {spec_avg:.1%} & {gen_avg:.1%} & {spec_win:.1%} & {tie:.1%} \\\\")

    if not has_data:
        md_lines.append("| (no data) | - | - | - | - |")
        tex_lines.append(r"(no data) & - & - & - & - \\")

    tex_lines.extend([r"\bottomrule", r"\end{tabular}", r"\end{table}", ""])
    md_lines.append("")

    return "\n".join(md_lines), "\n".join(tex_lines)


# ── Table 5: Token Cost Reduction ─────────────────────────────────────

def generate_table5(data: dict | None) -> tuple[str, str]:
    """Table 5: Token Cost Reduction."""
    md_lines = ["## Table 5: Token Cost Reduction (Claude-only vs KAJIBA)", ""]
    tex_lines = [
        r"\begin{table}[h]",
        r"\centering",
        r"\caption{Token Cost Reduction: Claude-only vs KAJIBA}",
        r"\label{tab:token-cost}",
        r"\begin{tabular}{lrr}",
        r"\toprule",
        r"Metric & Claude-only & KAJIBA \\",
        r"\midrule",
    ]
    md_lines.append("| Metric | Claude-only | KAJIBA |")
    md_lines.append("|--------|-------------|--------|")

    if data and "cost_analysis" in data:
        ca = data["cost_analysis"]
        co = ca.get("claude_only", {})
        kj = ca.get("kajiba", {})
        rd = ca.get("reduction", {})

        rows = [
            ("Total Tokens", f"{co.get('total_tokens', 0):,}", f"{kj.get('total_tokens', 0):,}"),
            ("Input Tokens", f"{co.get('input_tokens', 0):,}", f"{kj.get('input_tokens', 0):,}"),
            ("Output Tokens", f"{co.get('output_tokens', 0):,}", f"{kj.get('output_tokens', 0):,}"),
            ("Cost (USD)", f"${co.get('cost_usd', 0):.4f}", f"${kj.get('cost_usd', 0):.4f}"),
            ("Token Reduction", "-", f"{rd.get('token_reduction_rate', 0):.1%}"),
            ("Cost Reduction", "-", f"{rd.get('cost_reduction_rate', 0):.1%}"),
            ("Cost Saved", "-", f"${rd.get('cost_saved_usd', 0):.4f}"),
        ]

        for label, col1, col2 in rows:
            md_lines.append(f"| {label} | {col1} | {col2} |")
            tex_lines.append(f"{label} & {col1} & {col2} \\\\")

        # ルーティング内訳
        routing = ca.get("routing", {})
        md_lines.append("")
        md_lines.append(f"Routing: {routing.get('local', 0)} local, "
                        f"{routing.get('escalate', 0)} escalate "
                        f"({routing.get('local_rate', 0):.0%} local)")
    else:
        md_lines.append("| (no data) | - | - |")
        tex_lines.append(r"(no data) & - & - \\")

    tex_lines.extend([r"\bottomrule", r"\end{tabular}", r"\end{table}", ""])
    md_lines.append("")

    return "\n".join(md_lines), "\n".join(tex_lines)


# ── Table 6: Saku Compression ────────────────────────────────────────

def generate_table6(data: dict | None) -> tuple[str, str]:
    """Table 6: Saku Compression 効果."""
    md_lines = ["## Table 6: Saku Compression Effect", ""]
    tex_lines = [
        r"\begin{table}[h]",
        r"\centering",
        r"\caption{Saku Compression Effect}",
        r"\label{tab:saku-compression}",
        r"\begin{tabular}{lrrrrr}",
        r"\toprule",
        r"Group & Count & Reduction & Similarity & Latency (ms) \\",
        r"\midrule",
    ]
    md_lines.append("| Group | Count | Reduction | Similarity | Latency (ms) |")
    md_lines.append("|-------|-------|-----------|------------|--------------|")

    if data and "summary" in data:
        summary = data["summary"]

        # Overall
        overall = summary.get("overall", {})
        if overall:
            md_lines.append(f"| **Overall** | {overall.get('count', 0)} | "
                            f"{overall.get('avg_reduction_rate', 0):.1%} | "
                            f"{overall.get('avg_semantic_similarity', 0):.2f} | "
                            f"{overall.get('avg_latency_ms', 0):.0f} |")
            tex_lines.append(f"\\textbf{{Overall}} & {overall.get('count', 0)} & "
                             f"{overall.get('avg_reduction_rate', 0):.1%} & "
                             f"{overall.get('avg_semantic_similarity', 0):.2f} & "
                             f"{overall.get('avg_latency_ms', 0):.0f} \\\\")
            tex_lines.append(r"\midrule")

        # By domain
        by_domain = summary.get("by_domain", {})
        for domain in ["code", "medical", "general", "technical"]:
            stats = by_domain.get(domain, {})
            if stats:
                md_lines.append(f"| {domain} | {stats.get('count', 0)} | "
                                f"{stats.get('avg_reduction_rate', 0):.1%} | "
                                f"{stats.get('avg_semantic_similarity', 0):.2f} | "
                                f"{stats.get('avg_latency_ms', 0):.0f} |")
                tex_lines.append(f"{domain} & {stats.get('count', 0)} & "
                                 f"{stats.get('avg_reduction_rate', 0):.1%} & "
                                 f"{stats.get('avg_semantic_similarity', 0):.2f} & "
                                 f"{stats.get('avg_latency_ms', 0):.0f} \\\\")

        tex_lines.append(r"\midrule")

        # By length
        by_length = summary.get("by_length", {})
        for cat in ["short", "medium", "long"]:
            stats = by_length.get(cat, {})
            if stats:
                md_lines.append(f"| {cat} | {stats.get('count', 0)} | "
                                f"{stats.get('avg_reduction_rate', 0):.1%} | "
                                f"{stats.get('avg_semantic_similarity', 0):.2f} | "
                                f"{stats.get('avg_latency_ms', 0):.0f} |")
                tex_lines.append(f"{cat} & {stats.get('count', 0)} & "
                                 f"{stats.get('avg_reduction_rate', 0):.1%} & "
                                 f"{stats.get('avg_semantic_similarity', 0):.2f} & "
                                 f"{stats.get('avg_latency_ms', 0):.0f} \\\\")
    else:
        md_lines.append("| (no data) | - | - | - | - |")
        tex_lines.append(r"(no data) & - & - & - & - \\")

    tex_lines.extend([r"\bottomrule", r"\end{tabular}", r"\end{table}", ""])
    md_lines.append("")

    return "\n".join(md_lines), "\n".join(tex_lines)


# ── メイン処理 ────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="KAJIBA Paper Table Generator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--results-dir", type=str, default=str(RESULTS_DIR),
                        help=f"Results directory (default: {RESULTS_DIR})")
    parser.add_argument("--format", choices=["md", "tex", "both"], default="both",
                        help="Output format (default: both)")
    parser.add_argument("--output-dir", type=str, default=str(RESULTS_DIR),
                        help="Output directory for generated tables")
    args = parser.parse_args()

    results_dir = Path(args.results_dir)
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    print("Loading experiment results...", file=sys.stderr)

    # 各テーブルのデータ読み込み
    ollama_data = load_json(SCRIPTS_DIR / "bench_vs_ollama.json")
    gemma4_data = load_json(SCRIPTS_DIR / "bench_gemma4.json")
    uzu_data = find_latest_result(results_dir, "exp_a_uzu")
    cost_data = find_latest_result(results_dir, "exp_c_token_cost")
    saku_data = find_latest_result(results_dir, "exp_d_saku_compression")

    # テーブル生成
    all_md = ["# KAJIBA Paper Tables", ""]
    all_tex = [
        r"% KAJIBA Paper Tables",
        r"% Auto-generated by generate_paper_tables.py",
        r"\usepackage{booktabs}",
        "",
    ]

    tables = [
        ("Table 1", generate_table1(ollama_data)),
        ("Table 2", generate_table2(gemma4_data)),
        ("Table 3", generate_table3(uzu_data)),
        ("Table 4", generate_table4(results_dir)),
        ("Table 5", generate_table5(cost_data)),
        ("Table 6", generate_table6(saku_data)),
    ]

    for name, (md, tex) in tables:
        print(f"  Generated {name}", file=sys.stderr)
        all_md.append(md)
        all_tex.append(tex)

    # 出力
    if args.format in ("md", "both"):
        md_path = output_dir / "tables.md"
        with open(md_path, "w", encoding="utf-8") as f:
            f.write("\n".join(all_md))
        print(f"Markdown tables saved to: {md_path}", file=sys.stderr)

    if args.format in ("tex", "both"):
        tex_path = output_dir / "tables.tex"
        with open(tex_path, "w", encoding="utf-8") as f:
            f.write("\n".join(all_tex))
        print(f"LaTeX tables saved to: {tex_path}", file=sys.stderr)

    print("\nDone.", file=sys.stderr)


if __name__ == "__main__":
    main()
