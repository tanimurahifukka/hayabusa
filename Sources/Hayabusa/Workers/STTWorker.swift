// STT (音声認識) worker のスケルトン。Whisper / WhisperKit / whisper.cpp を
// 後段で結線する想定。本 PR では実装を入れず、jobType を登録できる枠と
// "not implemented" 失敗のみ提供する。
//
// 設計判断:
//   - 録音原本 / 全文 transcript を command-room に直接送らない（contract で禁止）
//   - 結果は要約済み + reference key のみ送る
//   - 大容量モデルは別 process または別 node (standalone) で運用するのを推奨

import Foundation

public struct STTWorker: Worker {
    public let jobType: String

    public init(jobType: String = "stt.whisper_call") {
        self.jobType = jobType
    }

    public func execute(job: JobEnvelope) async -> JobResultReport {
        return .failed(
            error: "stt_not_yet_implemented (jobType=\(jobType), jobId=\(job.jobId))",
            retryable: false
        )
    }
}
