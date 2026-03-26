import SwiftUI

struct ClusterTabView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ClusterViewModel()
    @State private var selectedNode: ClusterNode?

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.isClusterEnabled {
                ContentUnavailableView(
                    "Cluster Not Enabled",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Enable cluster mode in Settings to see cluster topology")
                )
            } else {
                HSplitView {
                    // Graph view
                    ClusterGraphView(
                        nodes: viewModel.nodes,
                        bandwidth: viewModel.bandwidth,
                        positions: viewModel.nodePositions,
                        onNodeTap: { node in selectedNode = node }
                    )
                    .frame(minWidth: 400)

                    // Node list
                    VStack(spacing: 0) {
                        Text("Nodes (\(viewModel.nodes.count))")
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()

                        List(viewModel.nodes) { node in
                            NodeRow(node: node, bandwidth: viewModel.bandwidthFor(nodeId: node.id))
                                .onTapGesture { selectedNode = node }
                        }
                    }
                    .frame(minWidth: 250, maxWidth: 350)
                }
            }
        }
        .popover(item: $selectedNode) { node in
            NodeDetailView(
                node: node,
                bandwidth: viewModel.bandwidthFor(nodeId: node.id)
            )
        }
        .onAppear { viewModel.startPolling(apiClient: appState.apiClient) }
        .onDisappear { viewModel.stopPolling() }
    }
}

private struct NodeRow: View {
    let node: ClusterNode
    let bandwidth: BandwidthSnapshot?

    var body: some View {
        HStack {
            Circle()
                .fill(ColorTheme.nodeColor(load: node.load, healthy: node.isHealthy))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(node.displayName)
                        .font(.caption.bold())
                    if node.isLocal {
                        Text("LOCAL")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.2))
                            .cornerRadius(3)
                    }
                }
                Text("\(node.backend) / \(node.slots) slots")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let bw = bandwidth {
                Text(Formatters.tokPerSec(bw.ewmaTokPerSec))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
