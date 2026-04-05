#!/usr/bin/env python3
"""Experiment D: Saku Compression 効果測定.

プロンプト圧縮（Saku）の効果をドメイン別・長さ別に計測する。
オリジナルと圧縮後のトークン数、削減率、レイテンシ、簡易的な意味保存度を測定。

Usage:
    python scripts/paper/exp_d_saku_compression.py
    python scripts/paper/exp_d_saku_compression.py --hayabusa-url http://localhost:8080 --samples 200
"""

from __future__ import annotations

import argparse
import asyncio
import json
import random
import statistics
import sys
import time
from pathlib import Path

import aiohttp

# ── 再現性 ───────────────────────────────────────────────────────────
random.seed(42)

SCRIPT_DIR = Path(__file__).resolve().parent
RESULTS_DIR = SCRIPT_DIR / "results"


# ── プロンプト生成 ────────────────────────────────────────────────────

# ドメイン別のプロンプトテンプレート
PROMPT_TEMPLATES = {
    "code": [
        # Short
        "Fix the bug in this Python function:\ndef add(a, b): return a - b",
        "What does the following regex match? ^[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\\.[a-zA-Z0-9-.]+$",
        "Convert this list comprehension to a for loop: [x**2 for x in range(10) if x % 2 == 0]",
        # Medium
        ("Write a Python class that implements a simple LRU cache with get and put methods. "
         "The cache should have a configurable maximum size. When the cache is full and a new item "
         "is added, the least recently used item should be evicted. Include type hints and docstrings. "
         "The get method should return None if the key is not found. The put method should update "
         "the value if the key already exists and move it to the most recently used position."),
        ("Review this code and suggest improvements:\n"
         "def process_data(data):\n"
         "    result = []\n"
         "    for item in data:\n"
         "        if item is not None:\n"
         "            if isinstance(item, str):\n"
         "                result.append(item.strip().lower())\n"
         "            elif isinstance(item, (int, float)):\n"
         "                result.append(str(item))\n"
         "            else:\n"
         "                result.append(str(item))\n"
         "    return result"),
        # Long
        ("You are tasked with designing a distributed task queue system similar to Celery. "
         "The system should support the following features: task submission with priority levels, "
         "retry logic with exponential backoff, dead letter queue for failed tasks, task result "
         "storage with configurable TTL, worker auto-scaling based on queue depth, task routing "
         "to specific worker pools, periodic task scheduling (cron-like), task chaining and "
         "group execution, rate limiting per task type, and monitoring/metrics endpoints. "
         "Please provide a detailed architecture document covering: component diagram, data flow, "
         "message format specification, failure handling strategies, scaling considerations, "
         "and technology choices with justification. Include code examples for the core interfaces "
         "in Python, showing the task decorator, worker class, and broker abstraction."),
    ],
    "medical": [
        # Short
        "バイタルサイン（血圧、脈拍、体温、SpO2）の正常範囲を教えてください。",
        "アスピリンの主な副作用と禁忌を列挙してください。",
        "心房細動のABCDスコアリングシステムについて簡潔に説明してください。",
        # Medium
        ("65歳男性。主訴は3日前からの労作時呼吸困難。既往歴に高血圧、糖尿病、慢性腎臓病（eGFR 35）。"
         "内服薬はアムロジピン5mg、メトホルミン500mg×2、ARB。来院時バイタル: BP 168/92, HR 98 irregular, "
         "SpO2 93%(室内気), BT 36.8。両側下肺野でcoarse crackles聴取。両下腿浮腫あり。"
         "BNP 1250 pg/mL, Cr 2.1, K 5.2。胸部X線で心拡大、肺うっ血像。"
         "この患者の初期対応と鑑別診断を述べてください。"),
        ("SOAP形式で以下の患者の診療録を作成してください: "
         "45歳女性、2週間前からの頭痛で来院。頭痛は片側性、拍動性、日常動作で増悪。"
         "悪心あり嘔吐なし。前兆としてギザギザの光が見える。月3-4回の頻度。"
         "家族歴: 母に片頭痛あり。神経学的所見は正常。"),
        # Long
        ("あなたは循環器内科専門医です。以下の症例について、詳細な診療計画を作成してください。\n\n"
         "患者: 72歳男性\n"
         "主訴: 2時間前からの胸痛（絞扼感）\n"
         "現病歴: 朝食後に前胸部の絞扼感が出現。安静でも改善せず、冷汗を伴う。"
         "ニトログリセリン舌下1回使用するも効果なし。\n"
         "既往歴: 高血圧（15年）、脂質異常症（10年）、2型糖尿病（8年）、"
         "5年前にPCI（LAD #7にDES留置）\n"
         "内服: アスピリン100mg、クロピドグレル75mg、ロスバスタチン10mg、"
         "テルミサルタン40mg、アムロジピン5mg、メトホルミン1000mg\n"
         "バイタル: BP 92/58, HR 110, SpO2 94%, BT 36.2\n"
         "12誘導心電図: V1-V4でST上昇2-3mm、II/III/aVFでreciprocal change\n"
         "血液検査: Trop-I 15.2 ng/mL(基準<0.04), CK 850, CK-MB 98, "
         "BNP 890, Cr 1.4, Hb 11.2, PLT 18万\n\n"
         "以下について述べてください:\n"
         "1. 診断名と根拠\n"
         "2. 緊急対応（Door-to-Balloon time目標含む）\n"
         "3. 薬物療法の詳細\n"
         "4. 合併症リスクの評価\n"
         "5. 退院後のフォローアップ計画"),
    ],
    "general": [
        # Short
        "東京タワーの高さは何メートルですか？",
        "光の三原色と色の三原色の違いを説明してください。",
        "日本の都道府県で面積が最大のものはどこですか？",
        # Medium
        ("以下のトピックについて、大学1年生向けのレポートの構成案を作成してください: "
         "「AIが雇用市場に与える影響」。序論、本論（3つの論点）、結論の構成で、"
         "各セクションで扱うべき内容と参考になる統計データの種類を示してください。"
         "レポートは2000字程度を想定しています。"),
        ("日本の少子高齢化問題について、以下の観点から分析してください: "
         "1) 現状の統計データ、2) 主要な原因、3) 経済への影響、"
         "4) 他国の成功事例、5) 日本で実施可能な対策案。"
         "各項目を200字程度で述べてください。"),
        # Long
        ("あなたは教育コンサルタントです。以下の条件で、高校生向けの「プログラミング入門」"
         "カリキュラムを設計してください。\n\n"
         "条件:\n"
         "- 対象: プログラミング未経験の高校1-2年生\n"
         "- 期間: 1学期（15回、各50分）\n"
         "- 使用言語: Python\n"
         "- 環境: Chromebook（ブラウザベースのIDEを使用）\n"
         "- 目標: 基本的なプログラミング概念の理解、簡単なアプリケーション制作\n\n"
         "以下を含めてください:\n"
         "1. 各回のテーマと学習目標\n"
         "2. 具体的な演習課題（各回1-2問）\n"
         "3. 評価方法と評価基準\n"
         "4. つまずきやすいポイントと対処法\n"
         "5. 最終プロジェクトの要件定義"),
    ],
    "technical": [
        # Short
        "TCP 3-way handshakeの手順をSYN/ACKフラグで説明してください。",
        "B+木とB木の違いを簡潔に説明してください。",
        "HTTPの冪等なメソッドをすべて挙げてください。",
        # Medium
        ("Kubernetes上でステートフルなアプリケーション（PostgreSQL）をデプロイする際の "
         "考慮事項を説明してください。StatefulSet、PersistentVolume、HeadlessService、"
         "Init Container、ReadinessProbe、バックアップ戦略について触れてください。"
         "また、Operatorパターンを使用する場合のメリットも述べてください。"),
        ("以下のSQLクエリのパフォーマンスを改善してください。テーブル定義とインデックス戦略も提案すること:\n"
         "SELECT o.order_id, c.customer_name, SUM(oi.quantity * oi.unit_price) as total\n"
         "FROM orders o\n"
         "JOIN customers c ON o.customer_id = c.customer_id\n"
         "JOIN order_items oi ON o.order_id = oi.order_id\n"
         "WHERE o.order_date BETWEEN '2024-01-01' AND '2024-12-31'\n"
         "AND c.country = 'Japan'\n"
         "GROUP BY o.order_id, c.customer_name\n"
         "HAVING SUM(oi.quantity * oi.unit_price) > 10000\n"
         "ORDER BY total DESC\n"
         "LIMIT 100;"),
        # Long
        ("あなたはシニアSREエンジニアです。以下のインシデントレポートを作成してください。\n\n"
         "インシデント概要:\n"
         "- 発生日時: 2024年3月15日 14:23 JST\n"
         "- 復旧日時: 2024年3月15日 16:45 JST\n"
         "- 影響範囲: 全ユーザーの約30%がAPI応答遅延を経験\n"
         "- 原因: データベースコネクションプールの枯渇\n"
         "- トリガー: マーケティングキャンペーンによるトラフィック急増（通常の3倍）\n\n"
         "以下のセクションを含めてください:\n"
         "1. エグゼクティブサマリー\n"
         "2. タイムライン（検知→調査→対応→復旧の各フェーズ）\n"
         "3. 根本原因分析（5 Whys手法を使用）\n"
         "4. 影響度の定量評価（エラー率、レイテンシ、売上影響）\n"
         "5. 再発防止策（短期・中期・長期）\n"
         "6. アクションアイテム（担当者、期限付き）"),
    ],
}


def generate_prompts(num_samples: int) -> list[dict]:
    """ドメイン別にプロンプトを生成する。"""
    prompts = []
    domains = list(PROMPT_TEMPLATES.keys())

    # 各ドメインから均等にサンプリング
    per_domain = num_samples // len(domains)
    remainder = num_samples % len(domains)

    for i, domain in enumerate(domains):
        templates = PROMPT_TEMPLATES[domain]
        count = per_domain + (1 if i < remainder else 0)

        for j in range(count):
            template = templates[j % len(templates)]
            char_len = len(template)

            # 長さカテゴリ
            if char_len < 200:
                length_category = "short"
            elif char_len <= 500:
                length_category = "medium"
            else:
                length_category = "long"

            prompts.append({
                "id": f"{domain}_{j+1:03d}",
                "domain": domain,
                "prompt": template,
                "char_length": char_len,
                "length_category": length_category,
                # トークン数概算（日本語は1文字≈1-2トークン、英語は4文字≈1トークン）
                "estimated_tokens": max(char_len // 3, 10),
            })

    random.shuffle(prompts)
    return prompts


# ── 簡易的な意味保存度チェック ────────────────────────────────────────

def simple_semantic_similarity(original: str, compressed: str) -> float:
    """簡易的な意味保存度スコア（BERTScoreの代替）。

    方法:
    1. 単語レベルのJaccard類似度
    2. 重要キーワードの保持率
    3. 長さ比率によるペナルティ
    """
    # 単語分割（簡易的）
    def tokenize(text: str) -> set[str]:
        # 英語: スペース区切り、日本語: 文字レベル
        words = set()
        for word in text.lower().split():
            # 句読点除去
            cleaned = word.strip(".,!?;:()[]{}\"'`")
            if len(cleaned) > 1:
                words.add(cleaned)
        # 日本語文字（2文字以上の連続）も追加
        import re
        jp_words = re.findall(r'[\u3040-\u9fff]{2,}', text)
        words.update(jp_words)
        return words

    orig_words = tokenize(original)
    comp_words = tokenize(compressed)

    if not orig_words:
        return 1.0 if not comp_words else 0.0

    # 1. Jaccard類似度
    intersection = orig_words & comp_words
    union = orig_words | comp_words
    jaccard = len(intersection) / len(union) if union else 0

    # 2. キーワード保持率（元の単語がどれだけ残っているか）
    retention = len(intersection) / len(orig_words) if orig_words else 0

    # 3. 長さ比率ペナルティ（極端に短すぎると減点）
    len_ratio = len(compressed) / len(original) if original else 0
    len_penalty = min(1.0, len_ratio * 2)  # 50%以上残っていればペナルティなし

    # 重み付き平均
    score = 0.4 * jaccard + 0.4 * retention + 0.2 * len_penalty
    return round(min(1.0, score), 4)


# ── Hayabusa compress 呼び出し ────────────────────────────────────────

async def compress_prompt(
    session: aiohttp.ClientSession,
    hayabusa_url: str,
    prompt: str,
) -> tuple[str, float, int, int]:
    """Hayabusaのcompressエンドポイントでプロンプトを圧縮。

    Returns:
        (compressed_text, latency_ms, original_tokens, compressed_tokens)
    """
    # compressエンドポイントが利用可能な場合
    payload = {
        "model": "default",
        "messages": [
            {
                "role": "system",
                "content": "Compress the following text while preserving all key information. "
                           "Remove redundancy, simplify phrasing, but keep technical accuracy. "
                           "Output only the compressed text.",
            },
            {"role": "user", "content": prompt},
        ],
        "max_tokens": max(len(prompt) // 2, 50),  # 最大でも元の半分
        "temperature": 0,
        "stream": False,
    }

    t0 = time.perf_counter()
    try:
        async with session.post(
            f"{hayabusa_url}/v1/chat/completions",
            json=payload,
            timeout=aiohttp.ClientTimeout(total=60),
        ) as resp:
            elapsed = (time.perf_counter() - t0) * 1000

            if resp.status != 200:
                return prompt, elapsed, 0, 0

            data = await resp.json()
            compressed = data.get("choices", [{}])[0].get("message", {}).get("content", prompt)

            # トークン数取得
            usage = data.get("usage", {})
            original_tokens = usage.get("prompt_tokens", len(prompt) // 3)
            compressed_tokens = usage.get("completion_tokens", len(compressed) // 3)

            return compressed, elapsed, original_tokens, compressed_tokens

    except Exception as e:
        elapsed = (time.perf_counter() - t0) * 1000
        print(f"  WARNING: compress failed: {e}", file=sys.stderr)
        return prompt, elapsed, 0, 0


# ── メイン処理 ────────────────────────────────────────────────────────

async def main():
    parser = argparse.ArgumentParser(
        description="Experiment D: Saku Compression 効果測定",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--hayabusa-url", default="http://localhost:8080",
                        help="Hayabusa server URL (default: http://localhost:8080)")
    parser.add_argument("--samples", type=int, default=100,
                        help="Number of prompts to test (default: 100)")
    parser.add_argument("--output", type=str, default=None,
                        help="Output JSON path (default: auto-generated)")
    args = parser.parse_args()

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    # プロンプト生成
    prompts = generate_prompts(args.samples)
    print(f"Generated {len(prompts)} prompts across domains", file=sys.stderr)

    # ドメイン・長さカテゴリの集計
    domain_counts = {}
    length_counts = {}
    for p in prompts:
        domain_counts[p["domain"]] = domain_counts.get(p["domain"], 0) + 1
        length_counts[p["length_category"]] = length_counts.get(p["length_category"], 0) + 1
    print(f"  Domains: {domain_counts}", file=sys.stderr)
    print(f"  Lengths: {length_counts}", file=sys.stderr)

    # ヘルスチェック
    server_available = True
    try:
        async with aiohttp.ClientSession() as session:
            async with session.get(
                f"{args.hayabusa_url}/v1/models",
                timeout=aiohttp.ClientTimeout(total=5),
            ) as resp:
                if resp.status != 200:
                    print(f"WARNING: Hayabusa returned status {resp.status}", file=sys.stderr)
                    server_available = False
    except Exception as e:
        print(f"WARNING: Cannot reach Hayabusa at {args.hayabusa_url}: {e}", file=sys.stderr)
        server_available = False

    if not server_available:
        print("ERROR: Hayabusa server not available. Start the server first.", file=sys.stderr)
        sys.exit(1)

    # 圧縮実験
    results = []
    async with aiohttp.ClientSession() as session:
        for i, prompt_data in enumerate(prompts):
            if (i + 1) % 10 == 0 or i == 0:
                print(f"  Processing [{i+1}/{len(prompts)}] {prompt_data['id']}...", file=sys.stderr)

            compressed_text, latency, orig_tokens, comp_tokens = await compress_prompt(
                session, args.hayabusa_url, prompt_data["prompt"]
            )

            # トークン数がAPIから取得できない場合は概算
            if orig_tokens == 0:
                orig_tokens = prompt_data["estimated_tokens"]
            if comp_tokens == 0:
                comp_tokens = max(len(compressed_text) // 3, 1)

            reduction_rate = 1.0 - (comp_tokens / orig_tokens) if orig_tokens > 0 else 0
            similarity = simple_semantic_similarity(prompt_data["prompt"], compressed_text)

            result_entry = {
                "id": prompt_data["id"],
                "domain": prompt_data["domain"],
                "length_category": prompt_data["length_category"],
                "char_length": prompt_data["char_length"],
                "original_tokens": orig_tokens,
                "compressed_tokens": comp_tokens,
                "reduction_rate": round(reduction_rate, 4),
                "latency_ms": round(latency, 2),
                "semantic_similarity": similarity,
                "original_preview": prompt_data["prompt"][:100],
                "compressed_preview": compressed_text[:100],
            }
            results.append(result_entry)

    # グループ別集計
    def aggregate_group(entries: list[dict]) -> dict:
        if not entries:
            return {}
        reduction_rates = [e["reduction_rate"] for e in entries]
        latencies = [e["latency_ms"] for e in entries]
        similarities = [e["semantic_similarity"] for e in entries]
        return {
            "count": len(entries),
            "avg_reduction_rate": round(statistics.mean(reduction_rates), 4),
            "stdev_reduction_rate": round(statistics.stdev(reduction_rates), 4) if len(reduction_rates) > 1 else 0,
            "avg_latency_ms": round(statistics.mean(latencies), 2),
            "avg_semantic_similarity": round(statistics.mean(similarities), 4),
            "total_original_tokens": sum(e["original_tokens"] for e in entries),
            "total_compressed_tokens": sum(e["compressed_tokens"] for e in entries),
        }

    # ドメイン別
    by_domain = {}
    for domain in ["code", "medical", "general", "technical"]:
        entries = [r for r in results if r["domain"] == domain]
        by_domain[domain] = aggregate_group(entries)

    # 長さカテゴリ別
    by_length = {}
    for cat in ["short", "medium", "long"]:
        entries = [r for r in results if r["length_category"] == cat]
        by_length[cat] = aggregate_group(entries)

    # 全体サマリー
    overall = aggregate_group(results)

    # 出力
    timestamp = time.strftime("%Y%m%d_%H%M%S")
    output_path = Path(args.output) if args.output else RESULTS_DIR / f"exp_d_saku_compression_{timestamp}.json"

    output_data = {
        "experiment": "exp_d_saku_compression",
        "timestamp": timestamp,
        "config": {
            "hayabusa_url": args.hayabusa_url,
            "num_samples": len(prompts),
        },
        "summary": {
            "overall": overall,
            "by_domain": by_domain,
            "by_length": by_length,
        },
        "results": results,
    }

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(output_data, f, indent=2, ensure_ascii=False)

    # サマリー表示
    print(f"\nResults saved to: {output_path}", file=sys.stderr)
    print(f"\n{'='*60}", file=sys.stderr)
    print(f"Saku Compression Results", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)
    print(f"  Overall reduction: {overall.get('avg_reduction_rate', 0):.1%}", file=sys.stderr)
    print(f"  Semantic similarity: {overall.get('avg_semantic_similarity', 0):.2f}", file=sys.stderr)
    print(f"  Avg latency: {overall.get('avg_latency_ms', 0):.0f}ms", file=sys.stderr)
    print(f"\n  By domain:", file=sys.stderr)
    for domain, stats in by_domain.items():
        if stats:
            print(f"    {domain:12s}: reduction={stats['avg_reduction_rate']:.1%}, "
                  f"similarity={stats['avg_semantic_similarity']:.2f}, "
                  f"latency={stats['avg_latency_ms']:.0f}ms", file=sys.stderr)
    print(f"\n  By length:", file=sys.stderr)
    for cat, stats in by_length.items():
        if stats:
            print(f"    {cat:8s}: reduction={stats['avg_reduction_rate']:.1%}, "
                  f"similarity={stats['avg_semantic_similarity']:.2f}, "
                  f"latency={stats['avg_latency_ms']:.0f}ms", file=sys.stderr)
    print(f"{'='*60}", file=sys.stderr)

    print(json.dumps(output_data, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    asyncio.run(main())
