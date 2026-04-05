#!/usr/bin/env python3
"""KAJIBA Elo Manager — ジャンル別Eloレーティング管理.

Usage:
    python scripts/elo_manager.py --show                     全ジャンルのチャンピオンマップ表示
    python scripts/elo_manager.py --update FIX-BUG model 0.85  Elo更新
    python scripts/elo_manager.py --history FIX-BUG           ジャンル別履歴表示
"""

from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CHAMPION_MAP_PATH = SCRIPT_DIR.parent / "models" / "champion_map.json"
HISTORY_PATH = SCRIPT_DIR / "results" / "elo_history.json"

# 初期Eloレーティング
DEFAULT_ELO = 1500
K_FACTOR = 32  # Elo K値（変動幅）

# 合格閾値
THRESHOLD_SCORE = 0.85          # 現場ベンチ正答率
THRESHOLD_CHAMPION_DELTA = 0.10  # チャンピオン比+10%
THRESHOLD_CLINICAL = 0.95       # O-CLINICAL用

# ── Champion Map ──────────────────────────────────────────────────

def load_champion_map() -> dict:
    if CHAMPION_MAP_PATH.exists():
        with open(CHAMPION_MAP_PATH) as f:
            return json.load(f)
    return {}


def save_champion_map(data: dict):
    CHAMPION_MAP_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(CHAMPION_MAP_PATH, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


# ── Elo Calculation ──────────────────────────────────────────────

def expected_score(elo_a: float, elo_b: float) -> float:
    return 1 / (1 + 10 ** ((elo_b - elo_a) / 400))


def update_elo(genre: str, model: str, score: float):
    """Arena結果からEloを更新。チャンピオン超えなら王座交代。"""
    champion_map = load_champion_map()
    history = load_history()

    current = champion_map.get(genre, {"model": "none", "elo": DEFAULT_ELO})
    current_elo = current.get("elo", DEFAULT_ELO)
    current_model = current.get("model", "none")

    # 新モデルのElo計算
    # スコアをElo変動に変換（0.5=引き分け基準）
    challenger_elo = current_elo  # 挑戦者の暫定Elo
    e = expected_score(challenger_elo, current_elo)
    new_elo = challenger_elo + K_FACTOR * (score - e)
    new_elo = round(new_elo)

    # 閾値判定
    threshold = THRESHOLD_CLINICAL if genre == "O-CLINICAL" else THRESHOLD_SCORE
    is_champion = (
        score >= threshold
        and (current_model == "none" or score >= (1 + THRESHOLD_CHAMPION_DELTA) * 0.5)
    )

    # 更新
    if is_champion or current_model == "none":
        champion_map[genre] = {"model": model, "elo": new_elo}
        print(f"👑 New champion for {genre}: {model} (Elo: {new_elo}, Score: {score:.3f})")
    else:
        print(f"   {genre}: {model} scored {score:.3f} (Elo: {new_elo}), champion remains {current_model}")

    save_champion_map(champion_map)

    # 履歴に追加
    history.append({
        "genre": genre,
        "model": model,
        "score": score,
        "elo": new_elo,
        "is_champion": is_champion,
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
    })
    save_history(history)


# ── History ──────────────────────────────────────────────────────

def load_history() -> list:
    if HISTORY_PATH.exists():
        with open(HISTORY_PATH) as f:
            return json.load(f)
    return []


def save_history(data: list):
    HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(HISTORY_PATH, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


# ── Display ──────────────────────────────────────────────────────

def show_champion_map():
    champion_map = load_champion_map()
    if not champion_map:
        print("No champions registered yet.")
        print("Run: python scripts/arena_bench.py --genre FIX-BUG --model <model>")
        return

    print()
    print("=" * 70)
    print("  KAJIBA Champion Map — ジャンル別チャンピオン一覧")
    print("=" * 70)
    print(f"{'Genre':<16} {'Model':<35} {'Elo':>6}")
    print("-" * 70)
    for genre, info in sorted(champion_map.items()):
        print(f"{genre:<16} {info['model']:<35} {info['elo']:>6}")
    print()


def show_history(genre: str | None = None):
    history = load_history()
    if genre:
        history = [h for h in history if h["genre"] == genre]
    if not history:
        print("No history found.")
        return

    print(f"{'Timestamp':<22} {'Genre':<14} {'Model':<30} {'Score':>6} {'Elo':>6} {'Champion':>8}")
    print("-" * 90)
    for h in history[-20:]:  # 直近20件
        champ = "👑" if h.get("is_champion") else ""
        print(f"{h['timestamp']:<22} {h['genre']:<14} {h['model']:<30} {h['score']:>6.3f} {h['elo']:>6} {champ:>8}")


# ── Main ──────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="KAJIBA Elo Manager")
    parser.add_argument("--show", action="store_true", help="Show champion map")
    parser.add_argument("--update", nargs=3, metavar=("GENRE", "MODEL", "SCORE"), help="Update Elo")
    parser.add_argument("--history", nargs="?", const="ALL", default=None, help="Show history")
    args = parser.parse_args()

    if args.show:
        show_champion_map()
    elif args.update:
        genre, model, score = args.update
        update_elo(genre, model, float(score))
    elif args.history is not None:
        genre = None if args.history == "ALL" else args.history
        show_history(genre)
    else:
        show_champion_map()


if __name__ == "__main__":
    main()
