# OpenPBX → command-room イベント契約 v1

- **schema id**: `command-room-pbx/event/v1`
- **owner**: command-room / OpenPBX（両 repo が source of truth）
- **status**: draft（Step 2 で固定中、Step 3 以降で実装）
- **対象 repo**: `command-room`, `OpenPBX`, `hayabusa`（参照のみ）
- **関連**: ADR 0011（Source Connector / Processing Pack）, CLAUDE §2.5 / §2.8.x（境界ガード）

---

## 1. 目的

OpenPBX が発生させた通話イベントを、**片方向**で command-room に通知するための versioned contract。
command-room はこのイベントを `ExternalEvent` / `CallRecord` に upsert し、後続の AutomationRule で `WorkItem` 化する。

**最重要原則**: OpenPBX は出す / command-room は決める / Hayabusa は処理する。

---

## 2. スコープと境界

### 含む
- 1 通の通話単位のメタデータ（誰が / どの内線 / どの kind / いつ）
- 録音ファイルの**参照情報のみ**（ファイル名 / 相対パス / バイト数 / sha256）

### 含まない（禁止）
- 録音バイナリそのもの
- 全文 transcript
- 署名付き URL（signed URL）
- 任意の token / secret / 認証情報
- command-room の内部 ID（command-room 側で発番）

> command-room 側 `containsForbiddenKey()` / `FORBIDDEN_PAYLOAD_KEYS` で reject される。違反するとイベントは upsert されず 4xx を返す。

---

## 3. Transport

2 通り。OpenPBX 側はどちらも実装するが、デフォルトは file drop。

### 3.1 file drop（既定）
- 既存 `data/inbox/<basename>.meta.json` (`command-room-pbx/v1`, 旧形式) は**温存**
- Web watcher が読み取り、本契約の v1 形式に**昇格**して `data/outbox-v1/<eventId>.json` に**別名で並置**
- `tmp` → atomic rename で原子性を担保
- command-room 側の inbox ingestor（Step 4 で実装）がこの outbox-v1 を消化

### 3.2 HTTP push（feature flag、optional）
- 送信先: command-room の **既存** `POST /api/v1/external-events`
- 認証: device-token（既存 `LocalNode` 流儀）
- envelope: command-room 側 ExternalEvent upsert schema に乗せる
  - `sourceType = "pbx_edge"`
  - `sourceAccountId = <pbxInstanceId>`
  - `externalId = <eventId>`
  - `payload = <本契約 v1 の本文>`
- SourceConnectorDefinition `key = "openpbx_edge"` を command-room catalog に追加（Step 5 で実装）

> command-room → OpenPBX 方向の push / Asterisk 直接操作は**禁止**。

---

## 4. Payload schema

```jsonc
{
  "schema": "command-room-pbx/event/v1",          // 固定
  "eventId": "openpbx:<pbxInstanceId>:<uniqueId>",
  "source": "openpbx",                            // 固定
  "pbxInstanceId": "clinic-main",                 // OpenPBX 側 env から
  "workspaceExternalKey": "tamura-hifuka",        // command-room の Workspace 識別子（external key）
  "call": {
    "uniqueId": "1779019798.0",                   // Asterisk UNIQUEID
    "kind": "same_day_reservation",               // §6 enum
    "direction": "inbound",                       // §7 enum
    "extension": "9001",                          // 特番 / 内線
    "callerId": "1001",
    "callerName": "Reception 1001",
    "calleeExtension": "9001",
    "durationSec": null                           // null 可（録音長から後で補填）
  },
  "recording": {                                  // null 可（no_recording のとき）
    "fileName": "1779019798.0-9001-1001.wav",
    "relativePath": "1779019798.0-9001-1001.wav",
    "contentType": "audio/wav",
    "sizeBytes": null,                            // 計算前は null
    "sha256": null                                // 計算前は null
  },
  "receivedAt": "2026-05-17T13:27:03Z"            // UTC ISO8601
}
```

### フィールド規約

| field | type | required | 補足 |
|---|---|---|---|
| `schema` | string | yes | 固定 `command-room-pbx/event/v1` |
| `eventId` | string | yes | §5 idempotency キー |
| `source` | string | yes | 固定 `openpbx` |
| `pbxInstanceId` | string | yes | 1 サイト 1 値。env `OPENPBX_INSTANCE_ID` |
| `workspaceExternalKey` | string | yes | command-room Workspace の external key |
| `call.uniqueId` | string | yes | Asterisk `${UNIQUEID}` 原本 |
| `call.kind` | enum | yes | §6 |
| `call.direction` | enum | yes | §7 |
| `call.extension` | string | yes | dialplan の `${EXTEN}` |
| `call.callerId` | string | yes | 不明時は空文字 |
| `call.callerName` | string | no | 不明時は空文字 or 省略 |
| `call.calleeExtension` | string | no | transfer 後の最終内線 |
| `call.durationSec` | int\|null | no | null 可 |
| `recording` | object\|null | yes | null = §6 `no_recording` |
| `recording.fileName` | string | yes | basename のみ。パス区切り不可 |
| `recording.relativePath` | string | yes | `data/recordings` 基点の相対パス。`..` 不可 |
| `recording.contentType` | string | yes | 既定 `audio/wav` |
| `recording.sizeBytes` | int\|null | no | lazy 計算可 |
| `recording.sha256` | string\|null | no | lazy 計算可。hex lowercase 64桁 |
| `receivedAt` | string | yes | UTC ISO8601 (`Z` 終端) |

---

## 5. eventId / idempotency

- フォーマット: `openpbx:<pbxInstanceId>:<uniqueId>`
- 同じ `eventId` の再送は**冪等**。command-room 側 `ExternalEvent.(workspaceId, sourceType, sourceAccountId, externalId)` ユニーク制約に乗る
- OpenPBX 側 watcher は SQLite `event_outbox(eventId, status, sentAt, attempts)` を持ち、送信済みは再送しない。command-room から 5xx の場合は exponential backoff で再送
- 順序保証**なし**（command-room 側は到着順に関わらず正しく処理できる設計）

---

## 6. `kind` enum

| value | 意味 |
|---|---|
| `same_day_reservation` | 特番 9001。当日予約録音 |
| `callback_request` | 特番 9002。折り返し依頼録音 |
| `no_recording` | 録音なしで終わった通話（IVR 途中で hangup 等） |
| 将来拡張 | enum 追加は minor。値の削除/改名は major |

未知 enum を受け取った command-room 側は `ExternalEvent` を `received` で保存し、AutomationRule で「未対応 kind」として握りつぶさず可視化する。

---

## 7. `direction` enum

| value | 意味 |
|---|---|
| `inbound` | 外線からの着信 |
| `outbound` | 外線への発信 |
| `internal` | 内線間 |

---

## 8. PII / 機密ハンドリング

- 録音原本 / 全文 transcript は**送らない**（送ったら command-room 側で reject）
- AI 結果（要約・分類）は本契約には乗らない。別 contract `hayabusa-call-result-v1`（Step 9/10 で定義）
- `callerId` / `callerName` は最小限。マスキングは command-room 側 storage policy で行う
- 署名付き URL / 認証 token を含めない

---

## 9. エラーと部分失敗

- file drop の場合: `data/outbox-v1/` に滞留したまま再試行
- HTTP push の場合: 4xx は永続失敗（schema 違反 / 禁止キー混入）→ outbox を `dead` に。5xx は backoff 再送
- command-room 側 422 (FORBIDDEN_PAYLOAD_KEYS) は OpenPBX 側でも `dead` 扱い。Web UI `/events` に表示し、人が contract 違反を直す

---

## 10. 旧 `command-room-pbx/v1` との関係

- 既存 `data/inbox/*.meta.json`（旧 v1）は**廃止しない**
- Web watcher が旧 → 新へ昇格する **upgrade.ts** を持つ（Step 3）
- 昇格時に補う値:
  - `eventId` = `openpbx:<env.OPENPBX_INSTANCE_ID>:<uniqueId>`
  - `pbxInstanceId` = env
  - `workspaceExternalKey` = env
  - `direction` = `kind` から推定（既定 `inbound`）
  - `sha256` / `sizeBytes` = 対応 wav から lazy 計算
- 旧形式に新フィールドを生やさない（破壊しない）

---

## 11. fixtures

ゴールデン値として、以下 3 件を 3 repo に同期配置する。

- `fixtures/openpbx-event-v1/same_day_reservation.meta.json` — sha256/sizeBytes が null（昇格直後の状態）
- `fixtures/openpbx-event-v1/callback_request.meta.json` — sha256/sizeBytes 計算済み（送信直前の状態）
- `fixtures/openpbx-event-v1/no_recording.meta.json` — `recording: null`

これらの fixture が 3 repo の試験で通れば contract が噛み合っていると見なす（完了条件）。

---

## 12. バージョン運用

- フィールド追加（optional） → minor。後方互換
- フィールド削除 / 改名 / enum 値削除 → major。新 schema id `command-room-pbx/event/v2` で並走
- 旧 v1 受信は最低 90 日サポート
- schema id は payload に必ず含める。版判定は string 比較
