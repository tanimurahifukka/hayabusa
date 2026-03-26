import SwiftUI

struct PerformanceTabView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = PerformanceViewModel()

    var body: some View {
        VStack(spacing: 16) {
            // Summary cards
            HStack(spacing: 16) {
                SummaryCard(
                    title: "Throughput",
                    value: Formatters.tokPerSec(viewModel.displayTokPerSec),
                    subtitle: viewModel.latestTokPerSec > 0 ? "live" : "last",
                    icon: "bolt.fill",
                    color: viewModel.latestTokPerSec > 0 ? .blue : .secondary
                )
                SummaryCard(
                    title: "Peak",
                    value: Formatters.tokPerSec(viewModel.peakTokPerSec),
                    icon: "arrow.up.to.line",
                    color: .purple
                )
                SummaryCard(
                    title: "Active Slots",
                    value: "\(viewModel.activeSlotCount)/\(viewModel.totalSlotCount)",
                    icon: "square.grid.2x2",
                    color: .green
                )
                if let mem = viewModel.currentMemory {
                    SummaryCard(
                        title: "Memory",
                        value: Formatters.bytes(mem.rssBytes),
                        icon: "memorychip",
                        color: .orange
                    )
                    SummaryCard(
                        title: "Pressure",
                        value: mem.pressure.capitalized,
                        icon: "gauge.medium",
                        color: mem.pressureLevel == .normal ? .green : .red
                    )
                }
            }
            .padding(.horizontal)

            // Charts
            HStack(spacing: 16) {
                ThroughputChart(dataPoints: viewModel.dataPoints)
                    .frame(maxWidth: .infinity)
                MemoryGauge(memory: viewModel.currentMemory)
                    .frame(width: 200)
            }
            .padding(.horizontal)

            // Slot utilization
            SlotUtilizationView(slots: viewModel.currentSlots)
                .padding(.horizontal)
        }
        .padding(.vertical)
        .onAppear { viewModel.startPolling(apiClient: appState.apiClient) }
        .onDisappear { viewModel.stopPolling() }
    }
}

private struct SummaryCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    let icon: String
    let color: Color

    var body: some View {
        GroupBox {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(color)
                Text(value)
                    .font(.title3.bold().monospacedDigit())
                HStack(spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(subtitle == "live" ? Color.green.opacity(0.2) : Color.secondary.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }
}
