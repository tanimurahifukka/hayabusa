import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    var openDashboard: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Status header
            HStack {
                Image(systemName: appState.serverState.sfSymbol)
                    .foregroundStyle(appState.serverState.color)
                Text(appState.serverState.label)
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal)

            // Error message
            if appState.serverState == .error, let err = appState.processManager.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            Divider()

            // Start / Stop button
            Button {
                if appState.serverState == .running || appState.serverState == .starting {
                    appState.stopServer()
                } else {
                    appState.startServer()
                }
            } label: {
                Label(
                    appState.serverState == .running || appState.serverState == .starting
                        ? "Stop Server" : "Start Server",
                    systemImage: appState.serverState == .running || appState.serverState == .starting
                        ? "stop.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(appState.serverState == .running ? .red : .green)
            .padding(.horizontal)

            // Model info
            if !appState.settings.modelPath.isEmpty {
                HStack {
                    Image(systemName: "cpu")
                        .foregroundStyle(.secondary)
                    Text(appState.settings.modelPath.components(separatedBy: "/").last ?? "")
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal)
            }

            Divider()

            // Open main window
            Button {
                openDashboard()
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Dashboard", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Hayabusa", systemImage: "power")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
        }
        .padding(.vertical)
        .frame(width: 280)
    }
}
