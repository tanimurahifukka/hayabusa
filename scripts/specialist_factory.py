#!/usr/bin/env python3
"""KAJIBA Specialist Factory — スペシャリストAI量産パイプライン.

データ収集 → 品質フィルタ → LoRA学習 → Arena評価 → 自動投入

Usage:
    python scripts/specialist_factory.py --list              スペシャリスト一覧
    python scripts/specialist_factory.py --status            全スペシャリストの状態
    python scripts/specialist_factory.py --train stripe      LoRA学習開始
    python scripts/specialist_factory.py --collect stripe    教師データ収集
    python scripts/specialist_factory.py --evaluate stripe   Arena評価
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from dataclasses import dataclass, asdict, field
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
MODELS_DIR = SCRIPT_DIR.parent / "models" / "specialists"
MODELS_DIR.mkdir(parents=True, exist_ok=True)

# ── スペシャリスト定義 ─────────────────────────────────────────────

@dataclass
class SpecialistDef:
    name: str
    base_model: str
    memory_mb: int
    port: int
    genres: list[str]
    sources: list[str]
    keywords: list[str]
    data_policy: str = "NORMAL"  # NORMAL / LOCAL_ONLY

    @property
    def model_id(self) -> str:
        return f"kajiba-{self.name}"


SPECIALISTS = [
    SpecialistDef(
        name="stripe-1.7b", base_model="Qwen3-1.7B", memory_mb=800, port=8089,
        genres=["IMPL-PAYMENT", "FIX-STRIPE"],
        sources=["stripe/stripe-node", "stripe/stripe-python", "stackoverflow:stripe", "reddit:r/stripe"],
        keywords=["payment", "webhook", "subscription", "checkout", "invoice", "refund"],
    ),
    SpecialistDef(
        name="supabase-1.7b", base_model="Qwen3-1.7B", memory_mb=800, port=8090,
        genres=["IMPL-DB", "FIX-SUPABASE"],
        sources=["supabase/supabase", "supabase/auth"],
        keywords=["RLS", "JWT", "OAuth", "session", "realtime", "storage"],
    ),
    SpecialistDef(
        name="vercel-1.7b", base_model="Qwen3-1.7B", memory_mb=800, port=8091,
        genres=["IMPL-INFRA", "FIX-VERCEL"],
        sources=["vercel/next.js", "vercel/commerce"],
        keywords=["edge", "deploy", "env", "build", "routing", "middleware"],
    ),
    SpecialistDef(
        name="tailwind-0.6b", base_model="Qwen3-0.6B", memory_mb=300, port=8092,
        genres=["IMPL-UI"],
        sources=["tailwindlabs/tailwindcss"],
        keywords=["className", "responsive", "darkMode", "component"],
    ),
    SpecialistDef(
        name="shadcn-0.6b", base_model="Qwen3-0.6B", memory_mb=300, port=8093,
        genres=["IMPL-UI"],
        sources=["shadcn-ui/ui"],
        keywords=["component", "variant", "theme", "radix"],
    ),
    SpecialistDef(
        name="dawn-1.7b", base_model="Qwen3-1.7B", memory_mb=800, port=8094,
        genres=["IMPL-API", "IMPL-UI", "IMPL-DB"],
        sources=["tanimurahifukka/*"],
        keywords=["DAWN", "SIGN", "CRM", "BOOK", "FORM", "MAIL", "DESK"],
    ),
    SpecialistDef(
        name="orca-0.6b", base_model="Qwen3-0.6B", memory_mb=300, port=8095,
        genres=["O-CLINICAL"],
        sources=["local:clinic_task_history/", "local:orca_manual/"],
        keywords=["ORCA", "レセプト", "保険請求", "患者登録"],
        data_policy="LOCAL_ONLY",
    ),
    SpecialistDef(
        name="soap-0.6b", base_model="Qwen3-0.6B", memory_mb=300, port=8096,
        genres=["O-CLINICAL"],
        sources=["local:soap_task_history/"],
        keywords=["SOAP", "カルテ", "主訴", "所見", "治療方針"],
        data_policy="LOCAL_ONLY",
    ),
    SpecialistDef(
        name="swift-1.7b", base_model="Qwen3-1.7B", memory_mb=800, port=8097,
        genres=["IMPL-ALGO", "FIX-BUG"],
        sources=["apple/swift-evolution", "ml-explore/mlx-swift", "tanimurahifukka/hayabusa"],
        keywords=["Swift", "MLX", "Metal", "async", "actor", "SwiftUI"],
    ),
    SpecialistDef(
        name="classify-0.6b", base_model="Qwen3-0.6B", memory_mb=300, port=8098,
        genres=["CLASSIFY"],
        sources=["auto-generated task classification examples"],
        keywords=["classify", "routing", "intent"],
    ),
]


# ── Training Data ─────────────────────────────────────────────────

@dataclass
class TrainingExample:
    input: str
    output: str
    source_url: str = ""
    created_at: str = ""
    quality_score: float = 0.0
    freshness_weight: float = 1.0


def get_data_path(specialist: SpecialistDef) -> Path:
    return MODELS_DIR / specialist.name / "training_data.jsonl"


def get_model_path(specialist: SpecialistDef) -> Path:
    return MODELS_DIR / specialist.name / "adapter"


# ── Commands ──────────────────────────────────────────────────────

def list_specialists():
    print()
    print("=" * 80)
    print("  KAJIBA Specialist Factory — スペシャリスト一覧")
    print("=" * 80)
    print(f"{'Name':<22} {'Base':<14} {'Mem':>6} {'Port':>5} {'Genres':<30} {'Policy'}")
    print("-" * 80)
    total_mem = 0
    for s in SPECIALISTS:
        genres_str = ",".join(s.genres)
        policy = "🔒 LOCAL" if s.data_policy == "LOCAL_ONLY" else ""
        print(f"{s.model_id:<22} {s.base_model:<14} {s.memory_mb:>5}MB {s.port:>5} {genres_str:<30} {policy}")
        total_mem += s.memory_mb
    print("-" * 80)
    print(f"{'合計メモリ':<22} {'':14} {total_mem:>5}MB")
    print(f"{'96GB中の使用率':<22} {'':14} {total_mem/1024/96*100:>5.1f}%")
    print()


def show_status():
    print()
    print("=" * 80)
    print("  KAJIBA Specialist Status")
    print("=" * 80)
    print(f"{'Name':<22} {'Data':>8} {'Trained':>8} {'Arena':>8} {'Champion':>8}")
    print("-" * 80)
    for s in SPECIALISTS:
        data_path = get_data_path(s)
        model_path = get_model_path(s)

        data_count = 0
        if data_path.exists():
            with open(data_path) as f:
                data_count = sum(1 for _ in f)

        trained = "Yes" if model_path.exists() else "No"
        arena = "—"  # TODO: Arena結果読み込み
        champion = "—"

        print(f"{s.model_id:<22} {data_count:>7}d {trained:>8} {arena:>8} {champion:>8}")
    print()


def collect_data(name: str):
    specialist = next((s for s in SPECIALISTS if s.name == name or s.model_id == f"kajiba-{name}"), None)
    if not specialist:
        print(f"Unknown specialist: {name}")
        print(f"Available: {', '.join(s.name for s in SPECIALISTS)}")
        return

    if specialist.data_policy == "LOCAL_ONLY":
        print(f"⚠️  {specialist.model_id} is LOCAL_ONLY. Collecting from local sources only.")
        print(f"   Sources: {specialist.sources}")
        print(f"   Place training data in: {get_data_path(specialist)}")
        return

    print(f"Collecting data for {specialist.model_id}...")
    print(f"Sources: {specialist.sources}")
    print(f"Keywords: {specialist.keywords}")
    print()
    print("TODO: GitHub API / Reddit API でデータ収集を実装")
    print(f"Output: {get_data_path(specialist)}")

    # データディレクトリ作成
    data_path = get_data_path(specialist)
    data_path.parent.mkdir(parents=True, exist_ok=True)


def train_specialist(name: str):
    specialist = next((s for s in SPECIALISTS if s.name == name or s.model_id == f"kajiba-{name}"), None)
    if not specialist:
        print(f"Unknown specialist: {name}")
        return

    data_path = get_data_path(specialist)
    if not data_path.exists():
        print(f"No training data found at {data_path}")
        print(f"Run: python scripts/specialist_factory.py --collect {name}")
        return

    print(f"Training {specialist.model_id}...")
    print(f"Base model: {specialist.base_model}")
    print(f"Data: {data_path}")
    print(f"Output: {get_model_path(specialist)}")
    print()
    print("TODO: MLX LoRA学習パイプラインを実装")
    print("  python -m mlx_lm.lora \\")
    print(f"    --model mlx-community/{specialist.base_model}-4bit \\")
    print(f"    --data {data_path} \\")
    print(f"    --adapter-path {get_model_path(specialist)} \\")
    print(f"    --iters 1000")


def evaluate_specialist(name: str):
    specialist = next((s for s in SPECIALISTS if s.name == name or s.model_id == f"kajiba-{name}"), None)
    if not specialist:
        print(f"Unknown specialist: {name}")
        return

    print(f"Evaluating {specialist.model_id}...")
    print(f"Genres: {specialist.genres}")
    print()
    print("TODO: Arena評価を実装")
    print(f"  python scripts/arena_bench.py --genre {specialist.genres[0]} --model {specialist.model_id}")


# ── Memory Layout ─────────────────────────────────────────────────

def show_memory_layout():
    print()
    print("=" * 80)
    print("  M3 Ultra 96GB 推奨メモリ配置")
    print("=" * 80)
    print(f"{'Role':<10} {'Port':>5} {'Model':<30} {'Genres':<25} {'Mem':>6}")
    print("-" * 80)
    print(f"{'親':10} {'8080':>5} {'—':30} {'Router':25} {'  100MB':>6}")

    total = 100  # 親ノード
    for s in SPECIALISTS:
        genres_str = ",".join(s.genres[:3])
        if len(s.genres) > 3:
            genres_str += "..."
        print(f"{'子':10} {s.port:>5} {s.model_id:<30} {genres_str:<25} {s.memory_mb:>5}MB")
        total += s.memory_mb

    # Qwen3.5-9B汎用ノード
    print(f"{'子':10} {'8081':>5} {'Qwen3.5-9B-MLX-4bit':<30} {'汎用（再判定）':<25} {'5037MB':>6}")
    total += 5037

    print("-" * 80)
    print(f"{'合計':10} {'':>5} {'':30} {'':25} {total:>5}MB")
    print(f"{'残り':10} {'':>5} {'':30} {'':25} {96*1024 - total:>5}MB")
    print()


# ── Main ──────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="KAJIBA Specialist Factory")
    parser.add_argument("--list", action="store_true", help="スペシャリスト一覧")
    parser.add_argument("--status", action="store_true", help="全スペシャリストの状態")
    parser.add_argument("--collect", metavar="NAME", help="教師データ収集")
    parser.add_argument("--train", metavar="NAME", help="LoRA学習開始")
    parser.add_argument("--evaluate", metavar="NAME", help="Arena評価")
    parser.add_argument("--memory", action="store_true", help="メモリ配置表示")
    args = parser.parse_args()

    if args.list:
        list_specialists()
    elif args.status:
        show_status()
    elif args.collect:
        collect_data(args.collect)
    elif args.train:
        train_specialist(args.train)
    elif args.evaluate:
        evaluate_specialist(args.evaluate)
    elif args.memory:
        show_memory_layout()
    else:
        list_specialists()
        show_memory_layout()


if __name__ == "__main__":
    main()
