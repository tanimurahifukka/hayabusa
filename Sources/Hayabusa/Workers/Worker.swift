// Worker protocol — 1 つの jobType を処理する責務。
// 個別 worker (Summarize / Classify / Extract / STT) はこの protocol を実装する。

import Foundation

public protocol Worker: Sendable {
    /// このワーカーが処理する jobType（command-room の Job.jobType と一致）。
    var jobType: String { get }

    /// 実行。JobResultReport を返す（成功でも失敗でも例外を投げず Report に
    /// 包む。実行中の例外は dispatcher 側で failed(retryable: true) に変換）。
    func execute(job: JobEnvelope) async -> JobResultReport
}
