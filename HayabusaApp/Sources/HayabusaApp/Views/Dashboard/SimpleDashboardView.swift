import SwiftUI

struct SimpleDashboardView: View {
    @Environment(AppState.self) private var appState
    @State private var serverVM = ServerViewModel()
    @State private var perfVM = PerformanceViewModel()
    @State private var clusterVM = ClusterViewModel()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Server status icon & label
            serverStatusSection

            Spacer()
                .frame(height: 32)

            // Performance indicator (only when running)
            if appState.serverState == .running {
                StatusIndicatorView(tokPerSec: perfVM.displayTokPerSec)
                    .transition(.opacity)

                Spacer()
                    .frame(height: 24)

                // Stats row
                statsRow
                    .transition(.opacity)
            }

            Spacer()

            // Start/Stop button
            startStopButton

            Spacer()
                .frame(height: 16)

            // Mode toggle
            modeToggle

            Spacer()
                .frame(height: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut, value: appState.serverState)
        .onAppear {
            serverVM.startMonitoring(appState: appState)
            perfVM.startPolling(apiClient: appState.apiClient)
            clusterVM.startPolling(apiClient: appState.apiClient)
        }
        .onDisappear {
            serverVM.stopMonitoring()
            perfVM.stopPolling()
            clusterVM.stopPolling()
        }
    }

    // MARK: - Server Status

    private var serverStatusSection: some View {
        VStack(spacing: 12) {
            Image(systemName: serverIcon)
                .font(.system(size: 64))
                .foregroundStyle(serverColor)
                .symbolEffect(.pulse, options: .repeating, isActive: appState.serverState == .starting)

            Text(serverLabel)
                .font(.title2.bold())
                .foregroundStyle(serverColor)
        }
    }

    private var serverIcon: String {
        switch appState.serverState {
        case .running:  return "hare.fill"
        case .starting: return "hare"
        case .stopped:  return "hare"
        case .error:    return "exclamationmark.triangle.fill"
        }
    }

    private var serverColor: Color {
        switch appState.serverState {
        case .running:  return .green
        case .starting: return .orange
        case .stopped:  return .secondary
        case .error:    return .red
        }
    }

    private var serverLabel: String {
        switch appState.serverState {
        case .running:  return Strings.Dashboard.serverRunning
        case .starting: return Strings.Dashboard.serverStarting
        case .stopped:  return Strings.Dashboard.serverStopped
        case .error:    return Strings.Dashboard.serverError
        }
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 32) {
            statItem(
                icon: "app.connected.to.app.below.fill",
                value: "\(perfVM.activeSlotCount)",
                label: Strings.Dashboard.activeConnections
            )

            if appState.settings.clusterEnabled {
                statItem(
                    icon: "point.3.connected.trianglepath.dotted",
                    value: "\(clusterVM.nodes.count)",
                    label: Strings.Dashboard.clusterNodes
                )
            }
        }
    }

    private func statItem(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.bold().monospacedDigit())
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Start/Stop Button

    private var startStopButton: some View {
        Group {
            if appState.serverState == .running {
                Button {
                    appState.stopServer()
                } label: {
                    Label(Strings.Dashboard.stopButton, systemImage: "stop.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: 240)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)
            } else {
                Button {
                    appState.startServer()
                } label: {
                    Label(Strings.Dashboard.startButton, systemImage: "play.fill")
                        .font(.title3.bold())
                        .frame(maxWidth: 240)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(appState.serverState == .starting)
            }
        }
    }

    // MARK: - Mode Toggle

    private var modeToggle: some View {
        Button {
            appState.settings.simpleMode = false
        } label: {
            Label(Strings.Dashboard.advancedMode, systemImage: "gear")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}
