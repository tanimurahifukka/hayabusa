2つの回答をローカルLLMで品質比較します（Arena用・トークン消費ゼロ）。

以下のコマンドを実行してください:

```bash
hayabusa judge --a "$ARGUMENTS"
```

引数の形式: --a "回答A" --b "回答B" --task "タスク説明"

出力JSON:
- winner: "a" or "b"
- scores: {"a": 0.0-1.0, "b": 0.0-1.0}
- reason: 判定理由
