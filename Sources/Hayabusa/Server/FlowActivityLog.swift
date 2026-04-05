// FlowActivityLog.swift — リクエスト履歴をFlow UIに提供
// UIが /flow/events をポーリングして実際の通信を可視化する

import Foundation

final class FlowActivityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [[String: Any]] = []

    // SSEリスナー
    private var listeners: [(String) -> Void] = []

    /// SSEリスナーを追加
    func addListener(_ handler: @escaping (String) -> Void) {
        lock.withLock { listeners.append(handler) }
    }

    /// 全リスナーにイベントをプッシュ
    private func broadcast(_ event: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        let sseMessage = "data: \(json)\n\n"
        lock.withLock {
            for listener in listeners {
                listener(sseMessage)
            }
        }
    }

    /// リスナーをクリア（切断時）
    func clearListeners() {
        lock.withLock { listeners.removeAll() }
    }

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
            if events.count > 200 { events.removeFirst() }
        }
        broadcast(event)
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
            if events.count > 200 { events.removeFirst() }
        }
        broadcast(event)
    }

    /// Claude Codeの活動ping
    func logPing(source: String) {
        let event: [String: Any] = [
            "type": "ping",
            "source": source,
            "timestamp": Date().timeIntervalSince1970,
        ]
        broadcast(event)
    }

    /// ポーリング用（フォールバック）
    func eventsSince(_ since: Double) -> [[String: Any]] {
        lock.withLock {
            events.filter { ($0["timestamp"] as? Double ?? 0) > since }
        }
    }
}
