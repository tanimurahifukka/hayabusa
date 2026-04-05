#!/usr/bin/env python3
"""KAJIBA Arena Bench — ジャンル別ベンチマーク + Elo更新.

Usage:
    python scripts/arena_bench.py --genre FIX-BUG --model mlx-community/Qwen3.5-9B-MLX-4bit
    python scripts/arena_bench.py --genre IMPL-ALGO --all-models
    python scripts/arena_bench.py --list-genres
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from dataclasses import dataclass, asdict
from pathlib import Path

import aiohttp

HAYABUSA_URL = "http://localhost:{port}/v1/chat/completions"
SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "results"
RESULTS_DIR.mkdir(exist_ok=True)

# ── ジャンル別ベンチ問題セット ─────────────────────────────────────

BENCH_PROBLEMS = {
    "FIX-BUG": [
        {
            "id": "fix_01", "prompt": "Fix the off-by-one error:\n```python\ndef is_sorted(lst):\n    for i in range(len(lst)):\n        if lst[i] > lst[i+1]:\n            return False\n    return True\n```",
            "system": "Fix the bug. Return only corrected code.",
            "check_keywords": ["len(lst) - 1", "range(len(lst)-1)", "range(1,"],
        },
        {
            "id": "fix_02", "prompt": "Fix this null pointer issue:\n```javascript\nfunction getUser(users, id) {\n  return users.find(u => u.id === id).name;\n}\n```",
            "system": "Fix the bug. Return only corrected code.",
            "check_keywords": ["?.", "if (", "|| ", "?? ", "? user", ": null", "undefined"],
        },
        {
            "id": "fix_03", "prompt": "Fix the race condition:\n```python\ncounter = 0\ndef increment():\n    global counter\n    counter += 1\n```",
            "system": "Fix the thread safety issue. Return only corrected code.",
            "check_keywords": ["Lock", "lock", "atomic", "threading"],
        },
        {
            "id": "fix_04", "prompt": "Fix the SQL injection:\n```python\ndef get_user(db, username):\n    query = f\"SELECT * FROM users WHERE name = '{username}'\"\n    return db.execute(query)\n```",
            "system": "Fix the security vulnerability. Return only corrected code.",
            "check_keywords": ["?", "parameterized", "placeholder", "%s", ":username"],
        },
        {
            "id": "fix_05", "prompt": "Fix the memory leak:\n```javascript\nconst cache = {};\nfunction getData(key) {\n  if (!cache[key]) cache[key] = fetchFromDB(key);\n  return cache[key];\n}\n```",
            "system": "Fix the memory issue. Return only corrected code.",
            "check_keywords": ["Map", "WeakMap", "LRU", "delete", "size", "limit", "max"],
        },
    ],
    "IMPL-ALGO": [
        {
            "id": "algo_01", "prompt": "Write a Python function `def binary_search(arr, target) -> int` that returns the index or -1.",
            "system": "Write only the function. No explanation.",
            "check_keywords": ["def binary_search", "return", "mid"],
        },
        {
            "id": "algo_02", "prompt": "Write a Python function `def merge_sort(arr) -> list` that sorts the array.",
            "system": "Write only the function. No explanation.",
            "check_keywords": ["def merge_sort", "return", "merge"],
        },
        {
            "id": "algo_03", "prompt": "Write `def lcs(s1, s2) -> int` returning the length of the longest common subsequence.",
            "system": "Write only the function. No explanation.",
            "check_keywords": ["def lcs", "return", "dp"],
        },
    ],
    "GEN-TEST": [
        {
            "id": "test_01", "prompt": "Generate pytest tests for:\n```python\ndef add(a, b): return a + b\ndef multiply(a, b): return a * b\n```",
            "system": "Generate comprehensive pytest test cases.",
            "check_keywords": ["def test_", "assert"],
        },
        {
            "id": "test_02", "prompt": "Generate jest tests for:\n```javascript\nfunction capitalize(str) { return str.charAt(0).toUpperCase() + str.slice(1); }\n```",
            "system": "Generate comprehensive jest test cases.",
            "check_keywords": ["test(", "expect(", "describe("],
        },
    ],
    "IMPL-API": [
        {
            "id": "api_01", "prompt": "Write a Next.js API route at /api/users that returns a list of users from a Supabase table.",
            "system": "Write the complete API route handler.",
            "check_keywords": ["supabase", "from(", "select", "export"],
        },
    ],
    "IMPL-UI": [
        {
            "id": "ui_01", "prompt": "Write a React component that renders a searchable dropdown list.",
            "system": "Write only the component code.",
            "check_keywords": ["useState", "onChange", "filter", "return"],
        },
    ],
}

# ── Bench Runner ──────────────────────────────────────────────────

@dataclass
class ProblemResult:
    id: str
    passed: bool
    latency_ms: float
    response: str = ""


async def run_problem(session, url, model, problem, max_tokens=1024):
    import re
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": problem["system"]},
            {"role": "user", "content": problem["prompt"]},
        ],
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": False,
    }

    t0 = time.perf_counter()
    try:
        async with session.post(url, json=payload, timeout=aiohttp.ClientTimeout(total=120)) as resp:
            raw = await resp.read()
            elapsed = (time.perf_counter() - t0) * 1000
            data = json.loads(raw.decode("utf-8", errors="replace"))
            content = data.get("choices", [{}])[0].get("message", {}).get("content", "")

            # thinkタグを除去
            content = re.sub(r"<think>.*?</think>\s*", "", content, flags=re.DOTALL)

            passed = any(kw.lower() in content.lower() for kw in problem["check_keywords"])
            return ProblemResult(id=problem["id"], passed=passed, latency_ms=elapsed, response=content[:500])
    except Exception as e:
        elapsed = (time.perf_counter() - t0) * 1000
        return ProblemResult(id=problem["id"], passed=False, latency_ms=elapsed, response=f"ERROR: {e}")


async def run_bench(genre: str, model: str, port: int):
    problems = BENCH_PROBLEMS.get(genre, [])
    if not problems:
        print(f"No problems defined for genre: {genre}", file=sys.stderr)
        return None

    url = HAYABUSA_URL.format(port=port)

    # Health check
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(f"http://localhost:{port}/health", timeout=aiohttp.ClientTimeout(total=5)) as r:
                if r.status != 200:
                    print(f"Server not ready at port {port}", file=sys.stderr)
                    return None
    except Exception:
        print(f"Server not running at port {port}", file=sys.stderr)
        return None

    print(f"Arena Bench: genre={genre} model={model} problems={len(problems)}", file=sys.stderr)

    results = []
    async with aiohttp.ClientSession() as session:
        for i, problem in enumerate(problems):
            result = await run_problem(session, url, model, problem)
            results.append(result)
            status = "PASS" if result.passed else "FAIL"
            print(f"  [{i+1}/{len(problems)}] {problem['id']}: {status} ({result.latency_ms:.0f}ms)", file=sys.stderr)

    solved = sum(1 for r in results if r.passed)
    total = len(results)
    score = solved / total if total > 0 else 0
    avg_latency = sum(r.latency_ms for r in results) / total if total > 0 else 0
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%SZ")

    output = {
        "genre": genre,
        "model": model,
        "score": round(score, 3),
        "problems_solved": solved,
        "problems_total": total,
        "avg_latency_ms": int(avg_latency),
        "timestamp": timestamp,
        "details": [asdict(r) for r in results],
    }

    # Save
    safe_model = model.replace("/", "_")
    safe_ts = timestamp.replace(":", "-")
    out_path = RESULTS_DIR / f"arena_{genre}_{safe_model}_{safe_ts}.json"
    with open(out_path, "w") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    print(f"Saved: {out_path}", file=sys.stderr)

    # Elo更新
    try:
        from elo_manager import update_elo
        update_elo(genre, model, score)
    except ImportError:
        pass

    return output


# ── Main ──────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="KAJIBA Arena Bench")
    parser.add_argument("--genre", default="FIX-BUG", help="Genre to benchmark")
    parser.add_argument("--model", default="local", help="Model name")
    parser.add_argument("--port", type=int, default=8080, help="Hayabusa port")
    parser.add_argument("--list-genres", action="store_true", help="List available genres")
    args = parser.parse_args()

    if args.list_genres:
        for genre in BENCH_PROBLEMS:
            print(f"  {genre}: {len(BENCH_PROBLEMS[genre])} problems")
        return

    result = asyncio.run(run_bench(args.genre, args.model, args.port))
    if result:
        print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
