// command-room → hayabusa の Job envelope。
// command-room の POST /api/v1/worker-nodes/jobs/lease response shape と整合。
//
// JSON 例 (lease response):
// {
//   "leasedAt": "2026-05-20T13:27:03Z",
//   "workerNodeId": "wn_abc",
//   "jobs": [
//     {
//       "jobId": "uuid",
//       "jobType": "llm.summarize_call",
//       "priority": "normal",
//       "payload": { ... jobType ごとの自由形 ... },
//       "attempts": 0,
//       "maxAttempts": 5
//     }
//   ]
// }

import Foundation

public struct LeaseRequest: Codable, Sendable {
    public let limit: Int
    /// command-room はこの配列に含まれる jobType だけを返す。
    /// 省略すると WorkerNode.capabilities.jobTypes の全集合が使われる。
    public let jobTypes: [String]?

    public init(limit: Int, jobTypes: [String]? = nil) {
        self.limit = limit
        self.jobTypes = jobTypes
    }
}

public struct JobEnvelope: Codable, Sendable {
    public let jobId: String
    public let jobType: String
    public let priority: String
    /// jobType ごとに形が異なる可変ペイロード。
    /// Swift では Data として保持し、各 Worker が再 decode する。
    public let payload: JSONValue
    public let attempts: Int
    public let maxAttempts: Int

    public init(
        jobId: String,
        jobType: String,
        priority: String,
        payload: JSONValue,
        attempts: Int,
        maxAttempts: Int
    ) {
        self.jobId = jobId
        self.jobType = jobType
        self.priority = priority
        self.payload = payload
        self.attempts = attempts
        self.maxAttempts = maxAttempts
    }
}

public struct LeaseResponse: Codable, Sendable {
    public let leasedAt: String
    public let workerNodeId: String?
    public let jobs: [JobEnvelope]
}

/// Job 完了報告。POST /api/v1/worker-nodes/jobs/:id/result の body。
public struct JobResultReport: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case succeeded
        case failed
    }

    public let status: Status
    /// status = succeeded のときに乗せる結果。各 jobType ごとに形が異なる。
    public let result: JSONValue?
    /// status = failed のときの簡易メッセージ（PII / token / transcript を含めない）。
    public let error: String?
    /// retry させたい失敗かどうか。指定無しなら command-room 側のデフォルト判定。
    public let retryable: Bool?

    public init(status: Status, result: JSONValue? = nil, error: String? = nil, retryable: Bool? = nil) {
        self.status = status
        self.result = result
        self.error = error
        self.retryable = retryable
    }

    public static func succeeded(result: JSONValue? = nil) -> JobResultReport {
        JobResultReport(status: .succeeded, result: result)
    }

    public static func failed(error: String, retryable: Bool = false) -> JobResultReport {
        JobResultReport(status: .failed, error: error, retryable: retryable)
    }
}

// -------------------------------------------------------------------------
// Free-form JSON 値。Swift の Codable 標準には JSON.any が無いので最小実装。
// 巨大ファイルや音声バイト列をそのまま入れないこと（contract で禁止）。
// -------------------------------------------------------------------------

public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int64.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// 簡易ヘルパ。object/array は path で辿る。
    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
