// hayabusa.config.json から NodeConfig を読み込む。
// YAML loader は Yams 依存を増やしたくないため JSON に統一する。
//
// 想定スキーマ:
// {
//   "node": {
//     "id": "edge-mac-studio-01",
//     "role": "main" | "sub" | "standalone",
//     "capabilities": { "jobTypes": ["llm.summarize_call", "llm.classify_call"] },
//     "policy": {
//       "maxConcurrentJobs": 4,
//       "acceptPriority": ["realtime","batch"],
//       "refuseWhenMemoryPressure": ["critical","emergency"],
//       "leaseBatchSize": 4,
//       "pollIntervalSeconds": 2.0
//     },
//     "lease": {
//       "enabled": true,
//       "commandRoomBaseUrl": "https://command-room.example",
//       "authTokenEnv": "HAYABUSA_WORKER_TOKEN"
//     }
//   }
// }

import Foundation

public struct LeaseEndpointConfig: Codable, Sendable {
    public let enabled: Bool
    /// command-room base URL (例: https://command-room.example)
    /// `/api/v1/worker-nodes/jobs/lease` 等が末尾に append される。
    public let commandRoomBaseUrl: String
    /// 認証 token を読む env var 名。直接 token を書かない。
    public let authTokenEnv: String

    public init(enabled: Bool, commandRoomBaseUrl: String, authTokenEnv: String) {
        self.enabled = enabled
        self.commandRoomBaseUrl = commandRoomBaseUrl
        self.authTokenEnv = authTokenEnv
    }
}

public struct NodeConfig: Codable, Sendable {
    public let id: String
    public let role: NodeRole
    public let capabilities: NodeCapability
    public let policy: NodePolicy
    public let lease: LeaseEndpointConfig

    public init(
        id: String,
        role: NodeRole,
        capabilities: NodeCapability,
        policy: NodePolicy,
        lease: LeaseEndpointConfig
    ) {
        self.id = id
        self.role = role
        self.capabilities = capabilities
        self.policy = policy
        self.lease = lease
    }

    private struct Wrapper: Codable {
        let node: NodeConfig
    }

    public static func standaloneDefault(id: String = "hayabusa-dev") -> NodeConfig {
        NodeConfig(
            id: id,
            role: .standalone,
            capabilities: NodeCapability(jobTypes: []),
            policy: NodePolicy(),
            lease: LeaseEndpointConfig(enabled: false, commandRoomBaseUrl: "", authTokenEnv: "")
        )
    }

    public static func load(fromJSONFile path: String) throws -> NodeConfig {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        return try loadJSON(data)
    }

    public static func loadJSON(_ data: Data) throws -> NodeConfig {
        let dec = JSONDecoder()
        let wrapper = try dec.decode(Wrapper.self, from: data)
        return wrapper.node
    }

    /// `HAYABUSA_CONFIG` env で path 指定されていればそこから読む。
    /// 失敗時は standalone default にフォールバック（既存挙動温存）。
    public static func loadFromEnvOrDefault(env: [String: String] = ProcessInfo.processInfo.environment) -> NodeConfig {
        if let path = env["HAYABUSA_CONFIG"], !path.isEmpty {
            do {
                return try load(fromJSONFile: path)
            } catch {
                FileHandle.standardError.write(Data("[Hayabusa] config load failed: \(error). Falling back to standalone.\n".utf8))
            }
        }
        return standaloneDefault()
    }

    public func resolveAuthToken(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard !lease.authTokenEnv.isEmpty else { return nil }
        let v = env[lease.authTokenEnv]
        return v?.isEmpty == false ? v : nil
    }
}
