// FlowActivityLog.swift — リクエスト履歴をFlow UIに提供
// UIが /flow/events をポーリングして実際の通信を可視化する

import Foundation

final class FlowActivityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: Any]] = []
    private var totalRequests = 0
    private var totalTokens = 0

    /// リクエスト開始
    func logRequest(id: String, prompt: String) {
        let event: [String: Any] = [
            "type": "request",
            "id": id,
            "timestamp": Date().timeIntervalSince1970,
            "prompt": prompt,
        ]
        lock.withLock {
            events.append(event)
            totalRequests += 1
            // 最大200件保持
            if events.count > 200 { events.removeFirst() }
        }
    }

    /// 完了
    func logCompletion(id: String, promptTokens: Int, completionTokens: Int) {
        let event: [String: Any] = [
            "type": "completion",
            "id": id,
            "timestamp": Date().timeIntervalSince1970,
            "prompt_tokens": promptTokens,
            "completion_tokens": completionTokens,
            "total_tokens": promptTokens + completionTokens,
        ]
        lock.withLock {
            events.append(event)
            totalTokens += promptTokens + completionTokens
            if events.count > 200 { events.removeFirst() }
        }
    }

    /// 指定タイムスタンプ以降のイベントを返す
    func eventsSince(_ since: Double) -> [[String: Any]] {
        lock.withLock {
            let filtered = events.filter {
                ($0["timestamp"] as? Double ?? 0) > since
            }
            return filtered
        }
    }
}
