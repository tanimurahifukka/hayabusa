// パイプラインの繋ぎ込み確認用 worker。
// jobType="echo" を受け取り、payload をそのまま result に詰めて succeeded を返す。
//
// command-room ↔ hayabusa の lease → result の往復を本物のモデルに依存せず
// pin できるので、最初の integration test に使う。

import Foundation

public struct EchoWorker: Worker {
    public let jobType: String = "echo"

    public init() {}

    public func execute(job: JobEnvelope) async -> JobResultReport {
        let now = ISO8601DateFormatter().string(from: Date())
        let result: JSONValue = .object([
            "echoedAt": .string(now),
            "jobId": .string(job.jobId),
            "receivedPayload": job.payload,
        ])
        return .succeeded(result: result)
    }
}
