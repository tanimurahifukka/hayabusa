# Hayabusa Judge

2つの回答をローカルLLMで品質比較する（Arena用）

## いつ使うか
複数の実装候補を比較評価したい時。

## 実行
```
$HAYABUSA_BIN judge --a "$A" --b "$B" --task "$TASK"
```

## 出力
```json
{"winner": "a", "scores": {"a": 0.87, "b": 0.71}, "reason": "回答Aの方がエラーハンドリングが適切", "genre": "FIX-BUG"}
```
