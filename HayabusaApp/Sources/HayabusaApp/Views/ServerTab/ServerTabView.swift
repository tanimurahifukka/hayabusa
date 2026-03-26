import SwiftUI

struct ServerTabView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = ServerViewModel()

    var body: some View {
        VStack(spacing: 20) {
            // Status card
            GroupBox {
                HStack(spacing: 16) {
                    Image(systemName: appState.serverState.sfSymbol)
                        .font(.system(size: 40))
                        .foregroundStyle(appState.serverState.color)
                        .symbolEffect(.pulse, isActive: appState.serverState == .starting)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.serverState.label)
                            .font(.title2.bold())
                        if appState.serverState == .running {
                            Text("http://127.0.0.1:\(appState.settings.port)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if appState.serverState == .error, let err = appState.processManager.lastError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if !appState.settings.modelPath.isEmpty {
                            Text(appState.settings.modelPath.components(separatedBy: "/").last ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    // Start/Stop button
                    Button {
                        if appState.serverState == .running || appState.serverState == .starting {
                            appState.stopServer()
                        } else {
                            appState.startServer()
                        }
                    } label: {
                        Image(systemName: appState.serverState == .running || appState.serverState == .starting
                              ? "stop.circle.fill" : "play.circle.fill")
                            .font(.system(size: 48))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        appState.serverState == .running || appState.serverState == .starting
                        ? Color.red : Color.green
                    )
                }
                .padding()
            }
            .padding(.horizontal)

            // Configuration summary
            GroupBox("Configuration") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Backend").foregroundStyle(.secondary)
                        Text(appState.settings.backend.uppercased())
                    }
                    GridRow {
                        Text("Slots").foregroundStyle(.secondary)
                        Text("\(appState.settings.slotCount)")
                    }
                    GridRow {
                        Text("Port").foregroundStyle(.secondary)
                        Text("\(appState.settings.port)")
                    }
                    if appState.settings.clusterEnabled {
                        GridRow {
                            Text("Cluster").foregroundStyle(.secondary)
                            Text("Enabled")
                                .foregroundStyle(.green)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal)

            // Log view
            LogView(lines: appState.processManager.logLines)
                .frame(maxHeight: .infinity)
                .padding(.horizontal)
        }
        .padding(.vertical)
        .onAppear { viewModel.startMonitoring(appState: appState) }
        .onDisappear { viewModel.stopMonitoring() }
    }
}
