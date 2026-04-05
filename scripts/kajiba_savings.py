#!/usr/bin/env python3
"""KAJIBA Savings Tracker — トークン節約率の集計・レポート.

Usage:
    python scripts/kajiba_savings.py --log classify 45 532     classify実行を記録（45トークン節約・532ms）
    python scripts/kajiba_savings.py --log compress 120 99     compress実行を記録（120→99トークン）
    python scripts/kajiba_savings.py --log ask 500 0           ask実行を記録（500トークン節約）
    python scripts/kajiba_savings.py --report                  節約率レポート表示
    python scripts/kajiba_savings.py --daily                   日次サマリー
"""

from __future__ import annotations

import argparse
import json
import time
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

SAVINGS_LOG = Path.home() / ".hayabusa" / "savings.jsonl"

# Claude Code 概算コスト（Opus 4.6, per 1K tokens）
CLAUDE_INPUT_COST_PER_1K = 0.015   # $15/MTok input
CLAUDE_OUTPUT_COST_PER_1K = 0.075  # $75/MTok output


def log_event(event_type: str, tokens_saved: int, latency_ms: int = 0, extra: dict = None):
    SAVINGS_LOG.parent.mkdir(parents=True, exist_ok=True)

    entry = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "type": event_type,
        "tokens_saved": tokens_saved,
        "latency_ms": latency_ms,
        "cost_saved_usd": round(tokens_saved / 1000 * CLAUDE_OUTPUT_COST_PER_1K, 6),
    }
    if extra:
        entry.update(extra)

    with open(SAVINGS_LOG, "a") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    print(f"Logged: {event_type} saved {tokens_saved} tokens (${entry['cost_saved_usd']:.4f})")


def load_events(days: int = None) -> list[dict]:
    if not SAVINGS_LOG.exists():
        return []

    events = []
    cutoff = None
    if days:
        cutoff = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%dT")

    with open(SAVINGS_LOG) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                event = json.loads(line)
                if cutoff and event["timestamp"] < cutoff:
                    continue
                events.append(event)
            except json.JSONDecodeError:
                continue

    return events


def report(days: int = None):
    events = load_events(days)
    if not events:
        print("No savings data found.")
        print(f"Log file: {SAVINGS_LOG}")
        print()
        print("Start tracking:")
        print("  python scripts/kajiba_savings.py --log classify 45 532")
        return

    period = f"直近{days}日" if days else "全期間"
    print()
    print("=" * 65)
    print(f"  KAJIBA Savings Report — {period}")
    print("=" * 65)

    # タイプ別集計
    by_type = defaultdict(lambda: {"count": 0, "tokens": 0, "cost": 0.0, "latency_total": 0})
    for e in events:
        t = by_type[e["type"]]
        t["count"] += 1
        t["tokens"] += e.get("tokens_saved", 0)
        t["cost"] += e.get("cost_saved_usd", 0)
        t["latency_total"] += e.get("latency_ms", 0)

    total_tokens = sum(t["tokens"] for t in by_type.values())
    total_cost = sum(t["cost"] for t in by_type.values())
    total_calls = sum(t["count"] for t in by_type.values())

    print(f"{'Type':<14} {'Calls':>6} {'Tokens Saved':>13} {'Cost Saved':>11} {'Avg ms':>8}")
    print("-" * 65)
    for typ, data in sorted(by_type.items()):
        avg_ms = data["latency_total"] / data["count"] if data["count"] else 0
        print(f"{typ:<14} {data['count']:>6} {data['tokens']:>13,} ${data['cost']:>10.4f} {avg_ms:>7.0f}")

    print("-" * 65)
    print(f"{'TOTAL':<14} {total_calls:>6} {total_tokens:>13,} ${total_cost:>10.4f}")
    print()

    # コスト削減率の推定
    # Claude Codeの平均的なトークン消費を仮定: 1リクエストあたり平均2000トークン
    estimated_total_claude = total_calls * 2000
    if estimated_total_claude > 0:
        reduction_rate = total_tokens / estimated_total_claude * 100
        print(f"  推定トークン削減率: {reduction_rate:.1f}%")
        print(f"  月間推定節約額: ${total_cost * 30 / max(1, days or 30):.2f}")
    print()


def daily_summary():
    events = load_events(days=30)
    if not events:
        print("No data.")
        return

    by_day = defaultdict(lambda: {"count": 0, "tokens": 0, "cost": 0.0})
    for e in events:
        day = e["timestamp"][:10]
        d = by_day[day]
        d["count"] += 1
        d["tokens"] += e.get("tokens_saved", 0)
        d["cost"] += e.get("cost_saved_usd", 0)

    print()
    print(f"{'Date':<12} {'Calls':>6} {'Tokens Saved':>13} {'Cost Saved':>11}")
    print("-" * 50)
    for day in sorted(by_day.keys()):
        d = by_day[day]
        print(f"{day:<12} {d['count']:>6} {d['tokens']:>13,} ${d['cost']:>10.4f}")

    total = sum(d["cost"] for d in by_day.values())
    total_tokens = sum(d["tokens"] for d in by_day.values())
    print("-" * 50)
    print(f"{'30-day total':<12} {'':>6} {total_tokens:>13,} ${total:>10.4f}")
    print()


def main():
    parser = argparse.ArgumentParser(description="KAJIBA Savings Tracker")
    parser.add_argument("--log", nargs="+", metavar=("TYPE", "TOKENS", "MS"), help="Log a savings event")
    parser.add_argument("--report", nargs="?", const=0, type=int, metavar="DAYS", help="Show report (optional: last N days)")
    parser.add_argument("--daily", action="store_true", help="Daily summary (30 days)")
    args = parser.parse_args()

    if args.log:
        event_type = args.log[0]
        tokens = int(args.log[1]) if len(args.log) > 1 else 0
        latency = int(args.log[2]) if len(args.log) > 2 else 0
        log_event(event_type, tokens, latency)
    elif args.report is not None:
        days = args.report if args.report > 0 else None
        report(days)
    elif args.daily:
        daily_summary()
    else:
        report()


if __name__ == "__main__":
    main()
