import SwiftUI

struct NodeDetailView: View {
    let node: ClusterNode
    let bandwidth: BandwidthSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Circle()
                    .fill(ColorTheme.nodeColor(load: node.load, healthy: node.isHealthy))
                    .frame(width: 12, height: 12)
                Text(node.displayName)
                    .font(.headline)
            }

            Divider()

            // Info grid
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Backend").foregroundStyle(.secondary)
                    Text(node.backend.uppercased())
                }
                GridRow {
                    Text("Model").foregroundStyle(.secondary)
                    Text(node.model.components(separatedBy: "/").last ?? node.model)
                        .lineLimit(1)
                }
                GridRow {
                    Text("Slots").foregroundStyle(.secondary)
                    Text("\(node.slots)")
                }
                GridRow {
                    Text("Healthy").foregroundStyle(.secondary)
                    Image(systemName: node.isHealthy ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(node.isHealthy ? .green : .red)
                }
                GridRow {
                    Text("Failures").foregroundStyle(.secondary)
                    Text("\(node.consecutiveFailures)")
                }

                Divider().gridCellUnsizedAxes(.horizontal)

                GridRow {
                    Text("Memory").foregroundStyle(.secondary)
                    Text(Formatters.bytes(node.totalMemory))
                }
                GridRow {
                    Text("RSS").foregroundStyle(.secondary)
                    Text(Formatters.bytes(node.rssBytes))
                }
                GridRow {
                    Text("Free").foregroundStyle(.secondary)
                    Text(Formatters.bytes(node.freeMemory))
                }
                GridRow {
                    Text("Pressure").foregroundStyle(.secondary)
                    Text(node.memoryPressure.capitalized)
                }

                if let bw = bandwidth {
                    Divider().gridCellUnsizedAxes(.horizontal)

                    GridRow {
                        Text("Bandwidth").foregroundStyle(.secondary)
                        Text(Formatters.tokPerSec(bw.ewmaTokPerSec))
                    }
                    GridRow {
                        Text("Active").foregroundStyle(.secondary)
                        Text("\(bw.activeRequests) requests")
                    }
                    GridRow {
                        Text("Total").foregroundStyle(.secondary)
                        Text("\(bw.totalRequests) requests / \(bw.totalTokens) tokens")
                    }
                }
            }
            .font(.caption)
        }
        .padding()
        .frame(width: 300)
    }
}
