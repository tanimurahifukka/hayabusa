# Hayabusa Bench

ジャンル別ベンチマークを実行してEloを更新する

## いつ使うか
新モデルを評価する時・週次Arenaバッチ時。

## 実行
```
$HAYABUSA_BIN bench --genre "$GENRE" --model "$MODEL"
```

## ジャンル一覧
IMPL-ALGO, IMPL-API, IMPL-UI, IMPL-DB, IMPL-PAYMENT
FIX-BUG, FIX-REFACTOR, FIX-PERF
GEN-TEST, GEN-DOCS

## 出力
```json
{"genre": "FIX-BUG", "model": "local", "score": 0.847, "problems_solved": 8, "problems_total": 10, "avg_latency_ms": 3420}
```
