import Foundation
import Network

// MARK: - ClusterNode

struct ClusterNode: Sendable {
    let id: String          // "host:port"
    let host: String
    let port: Int
    let backend: String
    let model: String
    var slots: Int
    let isLocal: Bool
    var isHealthy: Bool
    var lastSeen: Date
    var consecutiveFailures: Int

    // Memory info (updated periodically for local node)
    var totalMemory: UInt64 = 0
    var rssBytes: UInt64 = 0
    var freeMemory: UInt64 = 0
    var memoryPressure: String = "unknown"

    var baseURL: String { "http://\(host):\(port)" }
}

// MARK: - ClusterManager

/// Manages Bonjour-based LAN peer discovery for Hayabusa cluster mode.
///
/// Advertises the local node via `NWListener` and discovers peers via `NWBrowser`.
/// Uses NWConnection to resolve peer IPs, then queries HTTP API for node metadata.
/// Provides round-robin node selection with failure tracking.
final class ClusterManager: @unchecked Sendable {
    private let httpPort: Int
    private let backend: String
    private let model: String
    private let slots: Int

    private let lock = NSLock()
    private var nodes: [String: ClusterNode] = [:]
    private var roundRobinIndex = 0

    private var listener: NWListener?
    private var browser: NWBrowser?

    private let serviceType = "_hayabusa._tcp"

    init(httpPort: Int, backend: String, model: String, slots: Int) {
        self.httpPort = httpPort
        self.backend = backend
        self.model = model
        self.slots = slots
    }

    // MARK: - Start / Stop

    func start() {
        startListener()
        startBrowser()
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
    }

    // MARK: - Local IP Detection

    private static func getLocalIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var result: String?
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: addr.ifa_name)
            guard name != "lo0" else { continue }
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)
                if name == "en0" { return ip }
                if result == nil { result = ip }
            }
        }
        return result
    }

    // MARK: - Bonjour Advertising

    private func startListener() {
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: .any)

            let localIP = ClusterManager.getLocalIPv4() ?? "unknown"

            let txtRecord = NWTXTRecord([
                "port": "\(httpPort)",
                "host": localIP,
                "backend": backend,
                "model": model,
                "slots": "\(slots)",
            ])

            listener.service = NWListener.Service(
                name: nil,
                type: serviceType,
                txtRecord: txtRecord
            )

            listener.newConnectionHandler = { connection in
                // Accept connections for Bonjour peer resolution
                connection.stateUpdateHandler = { state in
                    if case .ready = state { connection.cancel() }
                    else if case .failed = state { connection.cancel() }
                }
                connection.start(queue: .global(qos: .background))
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port {
                        print("[Cluster] Bonjour advertising on port \(port) (HTTP: \(self.httpPort), IP: \(localIP))")
                    }
                case .failed(let error):
                    print("[Cluster] Listener failed: \(error)")
                default:
                    break
                }
            }

            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            print("[Cluster] Failed to create listener: \(error)")
        }
    }

    // MARK: - Peer Discovery

    private func startBrowser() {
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: "local."),
            using: .tcp
        )

        browser.browseResultsChangedHandler = { results, changes in
            for change in changes {
                switch change {
                case .added(let result):
                    self.handlePeerAdded(result)
                case .removed(let result):
                    self.handlePeerRemoved(result)
                default:
                    break
                }
            }
        }

        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[Cluster] Browsing for peers...")
            case .failed(let error):
                print("[Cluster] Browser failed: \(error)")
            default:
                break
            }
        }

        browser.start(queue: .global(qos: .utility))
        self.browser = browser
    }

    private func handlePeerAdded(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }

        // Resolve the endpoint IP via NWConnection, then query HTTP API
        let connection = NWConnection(to: result.endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let path = connection.currentPath,
                   let endpoint = path.remoteEndpoint,
                   case .hostPort(let host, _) = endpoint {
                    // Strip interface suffix (e.g., "192.168.11.34%en1" -> "192.168.11.34")
                    var rawHost = "\(host)"
                    // Remove IPv6 scope ID and any percent-encoded interface
                    if let pctIdx = rawHost.firstIndex(of: "%") {
                        rawHost = String(rawHost[rawHost.startIndex..<pctIdx])
                    }
                    let hostStr = rawHost

                    // Query the HTTP API to discover port and metadata
                    self.discoverNode(host: hostStr, serviceName: name)
                }
                connection.cancel()
            case .failed(let error):
                print("[Cluster] Failed to resolve \(name): \(error)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    /// Query the peer's HTTP health endpoint to discover its port and register it.
    /// Tries port 8080 first, then common ports.
    private func discoverNode(host: String, serviceName: String) {
        // Try the same port as ours first (most common case), then 8080
        let portsToTry = Array(Set([httpPort, 8080]))

        for tryPort in portsToTry {
            guard let url = URL(string: "http://\(host):\(tryPort)/health") else {
                print("[Cluster] Invalid URL for host=\(host) port=\(tryPort)")
                continue
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5

            let sem = DispatchSemaphore(value: 0)
            var success = false

            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                defer { sem.signal() }
                guard let self, error == nil,
                      let httpResp = response as? HTTPURLResponse,
                      httpResp.statusCode == 200 else { return }

                success = true
                let isLocal = self.isLocalAddress(host) && tryPort == self.httpPort
                let nodeId = "\(host):\(tryPort)"

                let node = ClusterNode(
                    id: nodeId,
                    host: host,
                    port: tryPort,
                    backend: self.backend,  // assume same backend for now
                    model: "",
                    slots: 0,
                    isLocal: isLocal,
                    isHealthy: true,
                    lastSeen: Date(),
                    consecutiveFailures: 0
                )

                self.lock.lock()
                self.nodes[nodeId] = node
                self.lock.unlock()
                print("[Cluster] Peer added: \(nodeId) (name: \(serviceName), local: \(isLocal))")
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 6)
            if success { return }
        }
        print("[Cluster] Could not reach \(serviceName) at \(host)")
    }

    // MARK: - Explicit Peer Registration

    /// Register a peer by address (e.g., "192.168.11.49:8080" or "192.168.11.49").
    func addExplicitPeer(_ address: String) {
        let parts = address.split(separator: ":")
        let host = String(parts[0])
        let port = parts.count > 1 ? Int(parts[1]) ?? 8080 : 8080

        let isLocal = self.isLocalAddress(host) && port == self.httpPort
        if isLocal {
            // Skip adding self as a remote peer
            return
        }

        // Verify the peer is reachable via health check
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let url = URL(string: "http://\(host):\(port)/health") else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10

            let sem = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                defer { sem.signal() }
                guard let self, error == nil,
                      let httpResp = response as? HTTPURLResponse,
                      httpResp.statusCode == 200 else {
                    print("[Cluster] Explicit peer \(host):\(port) unreachable")
                    return
                }

                let nodeId = "\(host):\(port)"
                let node = ClusterNode(
                    id: nodeId,
                    host: host,
                    port: port,
                    backend: "",
                    model: "",
                    slots: 0,
                    isLocal: false,
                    isHealthy: true,
                    lastSeen: Date(),
                    consecutiveFailures: 0
                )

                self.lock.lock()
                self.nodes[nodeId] = node
                self.lock.unlock()
                print("[Cluster] Explicit peer added: \(nodeId)")
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 12)
        }
    }

    private func handlePeerRemoved(_ result: NWBrowser.Result) {
        guard case .service(let name, _, _, _) = result.endpoint else { return }
        lock.lock()
        // Remove nodes that might correspond to this service
        let toRemove = nodes.filter { !$0.value.isLocal }
        // We don't have exact matching info, so just log for now
        lock.unlock()
        print("[Cluster] Service removed: \(name)")
    }

    private func isLocalAddress(_ host: String) -> Bool {
        if host == "127.0.0.1" || host == "::1" || host == "localhost"
            || host.hasPrefix("fe80::") || host == "0.0.0.0" {
            return true
        }
        if let localIP = ClusterManager.getLocalIPv4(), host == localIP {
            return true
        }
        return false
    }

    // MARK: - Round-Robin Node Selection

    func nextNode() -> ClusterNode? {
        lock.lock()
        defer { lock.unlock() }

        let healthyNodes = nodes.values.filter { node in
            if node.isLocal { return true }
            if !node.isHealthy { return false }
            if node.consecutiveFailures >= 3 {
                return Date().timeIntervalSince(node.lastSeen) > 30
            }
            return true
        }.sorted { $0.id < $1.id }

        guard !healthyNodes.isEmpty else { return nil }

        roundRobinIndex = roundRobinIndex % healthyNodes.count
        let node = healthyNodes[roundRobinIndex]
        roundRobinIndex += 1
        return node
    }

    func markFailed(nodeId: String) {
        lock.lock()
        if var node = nodes[nodeId] {
            node.consecutiveFailures += 1
            if node.consecutiveFailures >= 3 {
                node.isHealthy = false
                node.lastSeen = Date()
                print("[Cluster] Node \(nodeId) marked unhealthy (failures: \(node.consecutiveFailures))")
            }
            nodes[nodeId] = node
        }
        lock.unlock()
    }

    func markHealthy(nodeId: String) {
        lock.lock()
        if var node = nodes[nodeId] {
            node.consecutiveFailures = 0
            node.isHealthy = true
            node.lastSeen = Date()
            nodes[nodeId] = node
        }
        lock.unlock()
    }

    // MARK: - Memory Updates

    func updateLocalMemory(_ info: EngineMemoryInfo) {
        lock.lock()
        for key in nodes.keys {
            if nodes[key]!.isLocal {
                nodes[key]!.totalMemory = info.totalPhysical
                nodes[key]!.rssBytes = info.rssBytes
                nodes[key]!.freeMemory = info.freeEstimate
                nodes[key]!.memoryPressure = info.pressure
                nodes[key]!.slots = info.activeSlots
            }
        }
        lock.unlock()
    }

    // MARK: - Status

    func allNodes() -> [ClusterNode] {
        lock.lock()
        defer { lock.unlock() }
        return Array(nodes.values).sorted { $0.id < $1.id }
    }
}
