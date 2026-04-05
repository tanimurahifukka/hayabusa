ローカルLLM（Hayabusa）に直接質問します。Claude Codeのトークンを消費しません（$0）。

以下のコマンドを実行して、結果をそのままユーザーに表示してください:

```bash
curl -s http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d "{\"model\":\"local\",\"messages\":[{\"role\":\"user\",\"content\":\"$ARGUMENTS\"}],\"max_tokens\":1024,\"temperature\":0}" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])"
```

このコマンドはHayabusaサーバー（localhost:8080）に直接リクエストを投げます。
Claudeのトークンは一切消費しません。コスト$0で回答が得られます。
