# Hayabusa Classify

ローカルLLMでタスクを分類する（トークン消費なし・爆速）

## いつ使うか
タスクの種類・複雑度を判定したい時。
Claude Code自身のトークンを使う前に必ず呼ぶこと。
confidenceが低い場合は自分で処理する。

## 実行
```
$HAYABUSA_BIN classify "$ARGUMENTS"
```

## 出力
```json
{"category": "FIX-BUG", "confidence": 0.92, "latency_ms": 45, "action": "ROUTE_SPECIALIST"}
```

## ルーティング
- `ROUTE_SPECIALIST` — 専門スペシャリストに直行（confidence > 0.85）
- `RECLASSIFY_QWEN` — 汎用Qwen3.5-9Bで再判定（confidence 0.6〜0.85）
- `ESCALATE_CLAUDE` — Claude Codeで処理（confidence < 0.6 or O-CLINICAL）
