import Foundation
import Network

struct DiscoveredNode: Identifiable, Hashable {
    let id: String
    let name: String
    var host: String
    var port: UInt16

    var peerString: String { "\(host):\(port)" }
}

@Observable
final class BonjourScanner {
    private(set) var discoveredNodes: [DiscoveredNode] = []
    private(set) var isScanning = false

    private var browser: NWBrowser?
    private var timeoutTask: Task<Void, Never>?

    func startScan(timeout: TimeInterval = 5) {
        guard !isScanning else { return }
        isScanning = true
        discoveredNodes = []

        let params = NWParameters()
        params.includePeerToPeer = true

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_hayabusa._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: params)

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed:
                DispatchQueue.main.async {
                    self?.stopScan()
                }
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                self?.handleResults(results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser

        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.stopScan()
        }
    }

    func stopScan() {
        browser?.cancel()
        browser = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        isScanning = false
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            let nodeId = name

            if discoveredNodes.contains(where: { $0.id == nodeId }) { continue }

            // Resolve endpoint by creating a temporary connection
            let connection = NWConnection(to: result.endpoint, using: .tcp)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let path = connection.currentPath,
                       let endpoint = path.remoteEndpoint,
                       case .hostPort(let host, let port) = endpoint {
                        let hostStr: String
                        switch host {
                        case .ipv4(let addr):
                            hostStr = "\(addr)"
                        case .ipv6(let addr):
                            hostStr = "\(addr)"
                        case .name(let hostname, _):
                            hostStr = hostname
                        @unknown default:
                            hostStr = name
                        }

                        DispatchQueue.main.async {
                            let node = DiscoveredNode(
                                id: nodeId,
                                name: name,
                                host: hostStr,
                                port: port.rawValue
                            )
                            if !(self?.discoveredNodes.contains(where: { $0.id == nodeId }) ?? true) {
                                self?.discoveredNodes.append(node)
                            }
                        }
                    }
                    connection.cancel()
                case .failed, .cancelled:
                    break
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }
}
