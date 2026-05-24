# command-room Worker Lease / Result API — Hayabusa 連携 v1

> 状態: stable. cross-repo review (2026-05-24) で contract 化された。

Hayabusa は command-room のローカル Worker ノードとして動作する。
判断・ルーティングは行わず、command-room が割り当てた Job を lease →
実行 → result 投稿で完結する。

## 0. 境界 (CLAUDE.md §1.3 / command-room ADR 0009)

- Hayabusa は **Worker / AI 実行ノード** であり、ドメイン判断 (誰の WorkItem
  にするか、どの category にするか) は **しない**
- 完全な録音 / 全文 transcript / AI summary は Hayabusa のローカルから
  command-room に逐次返し、Hayabusa 側に持ち続けない (cache 例外あり)
- command-room から Hayabusa への push はしない。常に Hayabusa 起点で
  HTTP lease / result を叩く

## 1. 認証

- Bearer token (env: `HAYABUSA_WORKER_TOKEN`, または `config.node.lease.authTokenEnv` 指定の env)
- header: `Authorization: Bearer <token>`
- 同じ token を node identity として扱う。token が漏れたら revoke 必須

## 2. エンドポイント (command-room 側)

### 2.1 `POST /api/v1/worker-nodes/register`

Hayabusa 起動時に 1 回呼ぶ。capabilities / policy を declare する。

request body:

```jsonc
{
  "nodeId": "edge-mac-studio-dev-01",
  "role": "sub",                    // 'sub' (dispatcher), 'standalone' etc.
  "capabilities": {
    "jobTypes": ["echo", "stt.transcribe"]
  },
  "policy": {
    "maxConcurrentJobs": 2,
    "acceptPriority": [],           // 空配列 = 全 priority を accept
    "refuseWhenMemoryPressure": ["critical", "emergency"],
    "leaseBatchSize": 4,
    "pollIntervalSeconds": 2.0
  }
}
```

response: `200 { "ok": true }`

policy は command-room 側で zod validation され、`leaseBatchSize` は
`policy.maxConcurrentJobs` で clamp される (command-room 側で実装済み)。

### 2.2 `POST /api/v1/worker-nodes/jobs/lease`

実行可能 Job を pull する。空なら `[]` が返る。

request body:

```jsonc
{
  "nodeId": "edge-mac-studio-dev-01",
  "limit": 4                        // 上限。command-room 側で policy.leaseBatchSize に clamp
}
```

response:

```jsonc
[
  {
    "jobId": "job_01HX...",
    "jobType": "stt.transcribe",    // node.capabilities.jobTypes に含まれるものだけ来る
    "priority": "normal",           // 'low' | 'normal' | 'high' | 'urgent'
    "leaseExpiresAt": "2026-05-24T08:42:00Z",
    "payloadJson": { /* job-type-specific */ }
  }
]
```

`leaseExpiresAt` 内に result を投稿しない場合、command-room 側で lease は
再 dispatch される。Hayabusa 側は 30 秒以上かかる Job では明示的に
`PATCH /jobs/{id}/lease-extend` するか、result を一括投稿する。

### 2.3 `POST /api/v1/worker-nodes/jobs/{id}/result`

Job 完了 / 失敗時に投稿する。

success 時 request (stt.transcribe の例):

```jsonc
{
  "status": "succeeded",
  "result": {
    "transcript": "...transcript の本文 (cloud DB には保存されない)...",
    "transcriptRef": {
      "kind": "local_node_file",
      "provider": "local_node",
      "uri": "local-node://edge-mac-studio-01/transcripts/<callRecordId>.txt"
    },
    "language": "ja",
    "durationMs": 38000,
    "model": "whisper-large-v3"
  }
}
```

> **重要 (privacy / CLAUDE §2.5)**:
>
> 同じ `POST /api/v1/worker-nodes/jobs/{id}/result` エンドポイントで transcript
> 本文を HTTP body に乗せて送るが、command-room 側 `applySttResult` が:
>
> - 先頭 240 文字だけを `CallTranscriptSummary.summary` に保存
> - `transcriptCharLen` だけを保存
> - `transcriptRef` を `assertCloudSafeStoragePointer` で validate して保存
>   (kind=object_storage / local_node_file / obsidian_note 等の cloud-safe pointer)
> - **transcript 全文は Job.resultJson にも DB の他のフィールドにも書き込まない**
>   (`buildSttResultForStorage` が strip する)
>
> したがって専用の `transcript-full` エンドポイントは存在しない。
> 「Sensitive 経路」とはこの "送るが保存しない" 振る舞い全体を指す。
> Edge にある full transcript を後で見たい staff には、`transcriptRef.uri` を
> 表示して Local Node / Vault から手動アクセスしてもらう (UI は別 PR)。

failure 時 request:

```jsonc
{
  "status": "failed",
  "errorClass": "transient",        // 'transient' | 'permanent' | 'cancelled'
  "errorMessage": "whisper-cli exited with code 137 (killed)",
  "metricsJson": {
    "totalLatencyMs": 5000
  }
}
```

`errorClass=transient` は command-room 側で再 dispatch 対象。
`permanent` は再 dispatch せず WorkItem に上げる。

## 3. Hayabusa 側 config 例

`config/hayabusa.stt.dev.json`:

```jsonc
{
  "node": {
    "id": "edge-mac-studio-dev-01",
    "role": "sub",
    "capabilities": {
      "jobTypes": ["echo", "stt.transcribe"]
    },
    "policy": {
      "maxConcurrentJobs": 1,
      "acceptPriority": [],
      "refuseWhenMemoryPressure": ["critical", "emergency"],
      "leaseBatchSize": 2,
      "pollIntervalSeconds": 2.0
    },
    "lease": {
      "enabled": true,
      "commandRoomBaseUrl": "http://localhost:3001",
      "authTokenEnv": "HAYABUSA_WORKER_TOKEN"
    }
  }
}
```

必須 env:

| env | 用途 |
|---|---|
| `HAYABUSA_WORKER_TOKEN` | Bearer token (command-room から発行) |
| `HAYABUSA_WHISPER_BIN` | whisper-cli の絶対パス |
| `HAYABUSA_WHISPER_MODEL` | ggml-large-v3.bin 等のモデルファイル |
| `HAYABUSA_STT_TIMEOUT_SEC` | 任意。既定 300 |
| `HAYABUSA_STT_MAX_AUDIO_MB` | 任意。既定 200 |
| `HAYABUSA_STT_RECORDINGS_ROOT` | 任意。audio path の prefix 制限 |
| `HAYABUSA_STT_PROD_MODE` | 1 にすると result の transcript/audioPath を redact (sha256 prefix のみ) |

## 4. 不変条件 (smoke test の対象)

以下は cross-repo に share された不変条件。違反したら test が落ちる。

1. Hayabusa は capabilities に含まれない jobType を lease しない
2. lease batch size は `min(request.limit, policy.leaseBatchSize, policy.maxConcurrentJobs)` で clamp される
3. `refuseWhenMemoryPressure` が "critical" / "emergency" を含み、現在の OS memory pressure が match するなら、lease は 0 件で返る
4. result に transcript 全文が含まれていない (`resultJson.summary` までで止まる)
5. Hayabusa から command-room への接続は HTTPS かローカル網内のみ (CLAUDE §2.5)
6. authTokenEnv が未設定なら lease loop は起動しない (config.lease.enabled=false 相当)

## 5. 既知の制限

- Hayabusa 側の Server (`HayabusaServer.swift`) は OpenAI 互換の単純な
  推論サーバであり、command-room からは直接叩かない。lease 経路だけが
  command-room との contract
- SSE / streaming はまだ未実装 (README の Roadmap)
- transcript 全文は `/jobs/{id}/result` で送るが、Cloud DB には保存されない
  (上記 §2 参照)。Edge での参照 UI は別 PR で実装予定

## 6. 改版方針

- フィールド追加は minor (Hayabusa 側で読み飛ばし可)
- フィールド削除 / 改名 / enum 値削除は major
- error class の追加は minor (`transient` / `permanent` / `cancelled` の意味は変えない)
- contract 変更は 3 repo (Hayabusa / command-room / OpenPBX) いずれかが
  独断で進めず、ADR + 横断レビューでマージする
