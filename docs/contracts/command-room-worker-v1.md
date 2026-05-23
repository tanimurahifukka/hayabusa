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

success 時 request:

```jsonc
{
  "status": "succeeded",
  "resultJson": {
    "transcriptStatus": "completed",
    "summary": "発信者: 03-1234-5678 / 用件: 当日予約 / 希望時刻: 午後",
    "language": "ja",
    "durationSec": 38
  },
  "metricsJson": {
    "promptTokens": 1024,
    "completionTokens": 480,
    "totalLatencyMs": 12430,
    "modelId": "whisper-large-v3"
  }
}
```

> **重要 (privacy)**: `resultJson` に **transcript 全文を含めない**。
> 全文は別エンドポイント (`POST /api/v1/call-records/{id}/transcript-full`) に
> Sensitive データクラスとして直送し、`resultJson` には summary と
> meta だけ入れる。これは command-room CLAUDE §2.5 / ADR 0009 の Sensitive
> Originals 規約に対応する。

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
- transcript 全文の Sensitive 経路 (`/api/v1/call-records/{id}/transcript-full`)
  は command-room 側で実装中。stable 化は別 PR

## 6. 改版方針

- フィールド追加は minor (Hayabusa 側で読み飛ばし可)
- フィールド削除 / 改名 / enum 値削除は major
- error class の追加は minor (`transient` / `permanent` / `cancelled` の意味は変えない)
- contract 変更は 3 repo (Hayabusa / command-room / OpenPBX) いずれかが
  独断で進めず、ADR + 横断レビューでマージする
