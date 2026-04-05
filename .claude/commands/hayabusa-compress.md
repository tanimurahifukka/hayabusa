長いテキストをローカルLLMで圧縮します（トークン消費ゼロ・17-25%削減）。

以下のコマンドを実行して、結果をユーザーに報告してください:

```bash
/Users/tanimura/Desktop/hayabusa/.build/arm64-apple-macosx/release/HayabusaCLI compress "$ARGUMENTS"
```

出力JSON:
- compressed: 圧縮後テキスト
- original_tokens: 元のトークン数（概算）
- compressed_tokens: 圧縮後トークン数（概算）
- reduction_rate: 削減率（0.175 = 17.5%）
