import Foundation
import SwiftUI

@Observable
final class ClusterViewModel {
    private(set) var status: ClusterStatus?
    private(set) var nodes: [ClusterNode] = []
    private(set) var bandwidth: [BandwidthSnapshot] = []
    private(set) var nodePositions: [String: CGPoint] = [:]

    var isClusterEnabled: Bool { status?.isEnabled ?? false }
    private var timer: Timer?

    func startPolling(apiClient: APIClient) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.poll(apiClient: apiClient)
            }
        }
        // Immediate first poll
        Task { @MainActor in
            await poll(apiClient: apiClient)
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func poll(apiClient: APIClient) async {
        do {
            let s = try await apiClient.clusterStatus()
            self.status = s
            self.nodes = s.nodes ?? []
            self.bandwidth = s.bandwidth ?? []
            calculateLayout(size: CGSize(width: 400, height: 400))
        } catch {
            // Not in cluster mode or server down
        }
    }

    func calculateLayout(size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.35

        var positions: [String: CGPoint] = [:]
        let remoteNodes = nodes.filter { !$0.isLocal }

        // Local node at center
        if let local = nodes.first(where: \.isLocal) {
            positions[local.id] = center
        }

        // Remote nodes in a circle
        for (i, node) in remoteNodes.enumerated() {
            let angle = (2 * Double.pi * Double(i) / Double(max(remoteNodes.count, 1))) - .pi / 2
            let x = center.x + radius * cos(angle)
            let y = center.y + radius * sin(angle)
            positions[node.id] = CGPoint(x: x, y: y)
        }

        self.nodePositions = positions
    }

    func bandwidthFor(nodeId: String) -> BandwidthSnapshot? {
        bandwidth.first { $0.nodeId == nodeId }
    }
}
