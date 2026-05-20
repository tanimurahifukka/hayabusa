// command-room の Worker Node API を叩く HTTP client。
//
// endpoints:
//   POST /api/v1/worker-nodes/jobs/lease       — 受諾可能な Job を取得
//   POST /api/v1/worker-nodes/jobs/:id/result  — 結果を報告
//
// 認証: X-Command-Room-Worker-Token ヘッダで argon2id 検証される。
// token は NodeConfig.lease.authTokenEnv (環境変数) から取得。

import Foundation

public enum JobLeaseClientError: Error, CustomStringConvertible {
    case missingAuthToken(envName: String)
    case invalidURL(String)
    case http(status: Int, body: String)
    case transport(underlying: Error)
    case decode(underlying: Error)

    public var description: String {
        switch self {
        case .missingAuthToken(let envName):
            return "JobLeaseClient: auth token env '\(envName)' is empty"
        case .invalidURL(let s):
            return "JobLeaseClient: invalid URL '\(s)'"
        case .http(let status, let body):
            return "JobLeaseClient: HTTP \(status): \(body.prefix(200))"
        case .transport(let e):
            return "JobLeaseClient: transport: \(e)"
        case .decode(let e):
            return "JobLeaseClient: decode: \(e)"
        }
    }
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPTransport {}

public actor JobLeaseClient {
    private let baseURL: URL
    private let token: String
    private let transport: HTTPTransport
    private let timeoutSeconds: Double

    public init(
        baseURL: URL,
        token: String,
        transport: HTTPTransport = URLSession.shared,
        timeoutSeconds: Double = 15
    ) {
        self.baseURL = baseURL
        self.token = token
        self.transport = transport
        self.timeoutSeconds = timeoutSeconds
    }

    public static func from(config: NodeConfig, env: [String: String] = ProcessInfo.processInfo.environment) throws -> JobLeaseClient {
        guard let token = config.resolveAuthToken(env: env) else {
            throw JobLeaseClientError.missingAuthToken(envName: config.lease.authTokenEnv)
        }
        guard let baseURL = URL(string: config.lease.commandRoomBaseUrl) else {
            throw JobLeaseClientError.invalidURL(config.lease.commandRoomBaseUrl)
        }
        return JobLeaseClient(baseURL: baseURL, token: token)
    }

    public func lease(request: LeaseRequest) async throws -> LeaseResponse {
        let url = baseURL.appendingPathComponent("api/v1/worker-nodes/jobs/lease")
        return try await postJSON(url: url, body: request, decodeAs: LeaseResponse.self)
    }

    @discardableResult
    public func reportResult(jobId: String, report: JobResultReport) async throws -> JSONValue {
        let url = baseURL.appendingPathComponent("api/v1/worker-nodes/jobs/\(jobId)/result")
        return try await postJSON(url: url, body: report, decodeAs: JSONValue.self)
    }

    private func postJSON<Req: Encodable, Res: Decodable>(
        url: URL,
        body: Req,
        decodeAs: Res.Type
    ) async throws -> Res {
        var req = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(token, forHTTPHeaderField: "x-command-room-worker-token")
        do {
            req.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw JobLeaseClientError.decode(underlying: error)
        }

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await transport.data(for: req)
        } catch {
            throw JobLeaseClientError.transport(underlying: error)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw JobLeaseClientError.http(status: -1, body: "no HTTPURLResponse")
        }
        if !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw JobLeaseClientError.http(status: http.statusCode, body: body)
        }
        do {
            return try JSONDecoder().decode(decodeAs, from: data)
        } catch {
            throw JobLeaseClientError.decode(underlying: error)
        }
    }
}
