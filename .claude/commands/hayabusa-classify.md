ローカルLLMでタスクを分類します（トークン消費ゼロ・爆速）。

以下のコマンドを実行して、結果をユーザーに報告してください:

```bash
hayabusa classify "$ARGUMENTS"
```

出力JSON:
- category: タスクジャンル（FIX-BUG, IMPL-API, O-CLINICAL等）
- confidence: 確信度（0-1）
- action: ルーティング先
  - ROUTE_SPECIALIST → ローカル専門AI（$0）
  - RECLASSIFY_QWEN → 汎用モデルで再判定（$0）
  - ESCALATE_CLAUDE → Claude Codeで処理（トークン消費）

actionがROUTE_SPECIALISTの場合、該当タスクをHayabusaに投げることでトークン節約できます。
