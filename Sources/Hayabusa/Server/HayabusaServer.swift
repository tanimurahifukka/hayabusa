import Foundation
import Hummingbird

struct HayabusaServer {
    let engine: any InferenceEngine
    let port: Int
    let bindAddress: String
    let clusterManager: ClusterManager?
    let speculativeDecoder: SpeculativeDecoder?
    let kvQuantizeMode: KVQuantizeMode
    let layerSkipConfig: LayerSkipConfig?

    init(
        engine: any InferenceEngine,
        port: Int,
        bindAddress: String = "127.0.0.1",
        clusterManager: ClusterManager? = nil,
        speculativeDecoder: SpeculativeDecoder? = nil,
        kvQuantizeMode: KVQuantizeMode = .off,
        layerSkipConfig: LayerSkipConfig? = nil
    ) {
        self.engine = engine
        self.port = port
        self.bindAddress = bindAddress
        self.clusterManager = clusterManager
        self.speculativeDecoder = speculativeDecoder
        self.kvQuantizeMode = kvQuantizeMode
        self.layerSkipConfig = layerSkipConfig
    }

    func run() async throws {
        let router = Router()
        let engine = self.engine
        let clusterManager = self.clusterManager
        let speculativeDecoder = self.speculativeDecoder
        let kvQuantizeMode = self.kvQuantizeMode
        let layerSkipConfig = self.layerSkipConfig

        // GET /health
        router.get("health") { _, _ -> String in
            "{\"status\":\"ok\"}"
        }

        // ── Flow Activity Log（リクエスト履歴を保持） ──
        let flowLog = FlowActivityLog()

        // GET /flow — KAJIBA Flow UI
        router.get("flow") { _, _ -> Response in
            let html = KajibaFlowHTML.content
            return Response(
                status: .ok,
                headers: [.contentType: "text/html; charset=utf-8"],
                body: .init(byteBuffer: .init(string: html))
            )
        }

        // GET /flow/events — ポーリングフォールバック
        router.get("flow/events") { request, _ -> String in
            let since = request.uri.queryParameters.get("since")
                .flatMap { Double($0) } ?? 0
            let events = flowLog.eventsSince(since)
            let data = try JSONSerialization.data(withJSONObject: events, options: [])
            return String(data: data, encoding: .utf8) ?? "[]"
        }

        // GET /flow/stream — SSE（リアルタイムプッシュ）
        router.get("flow/stream") { _, _ -> Response in
            let (stream, continuation) = AsyncStream<ByteBuffer>.makeStream()

            // リスナー登録: イベント発生時に即座にSSEメッセージをプッシュ
            flowLog.addListener { message in
                var buf = ByteBuffer()
                buf.writeString(message)
                continuation.yield(buf)
            }

            return Response(
                status: .ok,
                headers: [
                    .contentType: "text/event-stream",
                    .init("Cache-Control")!: "no-cache",
                    .init("Connection")!: "keep-alive",
                    .init("Access-Control-Allow-Origin")!: "*",
                ],
                body: .init(asyncSequence: stream)
            )
        }

        // POST /v1/chat/completions
        router.post("v1/chat/completions") { request, context in
            let chatRequest = try await context.requestDecoder.decode(
                ChatRequest.self, from: request, context: context
            )

            // リクエスト開始をログ
            let requestId = UUID().uuidString.prefix(8)
            let prompt = chatRequest.messages.last?.content ?? ""
            flowLog.logRequest(id: String(requestId), prompt: String(prompt.prefix(80)))

            let result = try await engine.generate(
                messages: chatRequest.messages,
                maxTokens: chatRequest.max_tokens ?? 2048,
                temperature: chatRequest.temperature ?? 0.7,
                priority: SlotPriority(string: chatRequest.priority)
            )

            // 完了をログ
            flowLog.logCompletion(
                id: String(requestId),
                promptTokens: result.promptTokens,
                completionTokens: result.completionTokens
            )

            let response = ChatResponse(
                id: "hayabusa-\(requestId)",
                model: chatRequest.model ?? "local",
                content: result.text,
                promptTokens: result.promptTokens,
                completionTokens: result.completionTokens
            )

            let jsonData = try JSONEncoder().encode(response)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            return jsonString
        }

        // ── Project Mode: ファイルAPI ──

        // GET /flow/files?path=... — ディレクトリ一覧
        router.get("flow/files") { request, _ -> Response in
            let basePath = request.uri.queryParameters.get("path") ?? FileManager.default.currentDirectoryPath
            let fm = FileManager.default

            guard fm.fileExists(atPath: basePath) else {
                return Response(status: .notFound, body: .init(byteBuffer: .init(string: "{\"error\":\"not found\"}")))
            }

            var isDir: ObjCBool = false
            fm.fileExists(atPath: basePath, isDirectory: &isDir)

            if !isDir.boolValue {
                // ファイル内容を返す
                let data = fm.contents(atPath: basePath) ?? Data()
                let content = String(data: data, encoding: .utf8) ?? "(binary)"
                let escaped = content
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "")
                    .replacingOccurrences(of: "\t", with: "\\t")
                let json = "{\"type\":\"file\",\"path\":\"\(basePath)\",\"content\":\"\(escaped)\"}"
                return Response(
                    status: .ok,
                    headers: [.contentType: "application/json"],
                    body: .init(byteBuffer: .init(string: json))
                )
            }

            // ディレクトリ一覧
            let items = (try? fm.contentsOfDirectory(atPath: basePath)) ?? []
            let entries = items
                .filter { !$0.hasPrefix(".") }
                .sorted()
                .prefix(100)
                .map { name -> String in
                    let full = (basePath as NSString).appendingPathComponent(name)
                    var d: ObjCBool = false
                    fm.fileExists(atPath: full, isDirectory: &d)
                    return "{\"name\":\"\(name)\",\"isDir\":\(d.boolValue)}"
                }
            let json = "{\"type\":\"dir\",\"path\":\"\(basePath)\",\"entries\":[\(entries.joined(separator: ","))]}"
            return Response(
                status: .ok,
                headers: [.contentType: "application/json"],
                body: .init(byteBuffer: .init(string: json))
            )
        }

        // GET /slots — diagnostic endpoint
        router.get("slots") { _, _ -> String in
            let summary = engine.slotSummary()
            let slots = summary.map { slot in
                "{\"index\":\(slot.index),\"state\":\"\(slot.state)\",\"priority\":\"\(slot.priority)\",\"pos\":\(slot.pos)}"
            }
            return "[\(slots.joined(separator: ","))]"
        }

        // GET /v1/memory — memory status (available for any backend)
        router.get("v1/memory") { _, _ -> String in
            if let info = engine.memoryInfo() {
                return """
                {"totalPhysical":\(info.totalPhysical),"rssBytes":\(info.rssBytes),\
                "freeEstimate":\(info.freeEstimate),"activeSlots":\(info.activeSlots),\
                "pressure":"\(info.pressure)","slots":\(engine.slotCount)}
                """
            }
            return "{\"pressure\":\"unknown\"}"
        }

        // GET /v1/cluster/status — cluster node listing with memory info
        router.get("v1/cluster/status") { _, _ -> String in
            // Update local node memory before responding
            if let cm = clusterManager, let info = engine.memoryInfo() {
                cm.updateLocalMemory(info)
            }

            guard let cm = clusterManager else {
                return "{\"cluster\":false}"
            }
            let nodes = cm.allNodes()
            let nodesJson = nodes.map { node in
                """
                {"id":"\(node.id)","host":"\(node.host)","port":\(node.port),\
                "backend":"\(node.backend)","model":"\(node.model)","slots":\(node.slots),\
                "isLocal":\(node.isLocal),"isHealthy":\(node.isHealthy),\
                "consecutiveFailures":\(node.consecutiveFailures),\
                "totalMemory":\(node.totalMemory),"rssBytes":\(node.rssBytes),\
                "freeMemory":\(node.freeMemory),"memoryPressure":"\(node.memoryPressure)"}
                """
            }
            let bandwidthJson = cm.bandwidthSnapshots().map { s in
                """
                {"nodeId":"\(s.nodeId)","isLocal":\(s.isLocal),\
                "ewmaTokPerSec":\(String(format: "%.1f", s.ewmaTokPerSec)),\
                "activeRequests":\(s.activeRequests),\
                "totalRequests":\(s.totalRequests),"totalTokens":\(s.totalTokens)}
                """
            }
            return """
            {"cluster":true,"routing":"uzu",\
            "nodes":[\(nodesJson.joined(separator: ","))],\
            "bandwidth":[\(bandwidthJson.joined(separator: ","))]}
            """
        }

        // GET /v1/stats — speculative decoding & KV quantization metrics
        router.get("v1/stats") { _, _ -> String in
            var parts: [String] = []

            // Speculative decoding metrics
            if let sd = speculativeDecoder {
                let m = sd.metrics
                parts.append("""
                "speculative":{\
                "enabled":true,\
                "speculativeTokens":\(4),\
                "totalDraftTokens":\(m.totalDraftTokens),\
                "acceptedTokens":\(m.acceptedTokens),\
                "acceptanceRate":\(String(format: "%.4f", m.acceptanceRate)),\
                "totalGenerations":\(m.totalGenerations),\
                "totalCompletionTokens":\(m.totalCompletionTokens),\
                "effectiveTokPerSec":\(String(format: "%.1f", m.totalGenerations > 0 ? Double(m.totalCompletionTokens) / Double(m.totalGenerations) : 0))}
                """)
            } else {
                parts.append("\"speculative\":{\"enabled\":false}")
            }

            // KV cache quantization info
            let kvEnabled = kvQuantizeMode != .off
            parts.append("""
            "kvQuantize":{\
            "enabled":\(kvEnabled),\
            "mode":"\(kvQuantizeMode.rawValue)",\
            "description":"\(kvQuantizeMode.description)"}
            """)

            // Layer skipping info
            if let ls = layerSkipConfig {
                parts.append("\"layerSkip\":\(ls.statsJSON)")
            } else {
                parts.append("\"layerSkip\":{\"enabled\":false}")
            }

            // Memory info
            if let info = engine.memoryInfo() {
                parts.append("""
                "memory":{\
                "totalPhysical":\(info.totalPhysical),\
                "rssBytes":\(info.rssBytes),\
                "freeEstimate":\(info.freeEstimate),\
                "pressure":"\(info.pressure)"}
                """)
            }

            return "{\(parts.joined(separator: ","))}"
        }

        let app = Application(
            router: router,
            configuration: .init(address: .hostname(bindAddress, port: port))
        )
        try await app.runService()
    }
}
