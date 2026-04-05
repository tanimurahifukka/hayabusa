# Hayabusa Compress

長いプロンプトをSaku圧縮してトークンを削減する

## いつ使うか
500トークン以上のプロンプトをLLMに投げる前。
17.5%削減が期待できる。

## 実行
```
$HAYABUSA_BIN compress "$ARGUMENTS"
```

## 出力
```json
{"compressed": "圧縮後テキスト", "original_tokens": 120, "compressed_tokens": 99, "reduction_rate": 0.175}
```
