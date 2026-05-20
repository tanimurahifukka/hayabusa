// このノードが受諾する Job.jobType（command-room の Job.jobType と一致）。
//
// 例:
//   llm.summarize_call    要約
//   llm.classify_call     分類
//   llm.extract_fields    構造化抽出
//   stt.whisper_call      音声認識
//   echo                  動作確認用（command-room → hayabusa の lease 経路を pin）
//
// 文字列ベース。enum にしない理由は command-room 側の jobType 追加に毎回
// 再ビルド要求すると運用が苦しいため。policy は YAML / JSON で配布される。

import Foundation

public struct NodeCapability: Codable, Sendable, Hashable {
    /// このノードが pull できる Job.jobType の配列。
    public let jobTypes: [String]

    public init(jobTypes: [String]) {
        self.jobTypes = jobTypes
    }

    public func includes(_ jobType: String) -> Bool {
        jobTypes.contains(jobType)
    }
}
