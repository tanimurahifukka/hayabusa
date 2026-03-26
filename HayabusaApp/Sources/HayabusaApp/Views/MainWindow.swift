import SwiftUI

struct MainWindow: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab = 0

    var body: some View {
        if appState.settings.simpleMode {
            SimpleDashboardView()
                .environment(appState)
        } else {
            advancedView
        }
    }

    private var advancedView: some View {
        VStack(spacing: 0) {
            // Simple mode toggle at top
            HStack {
                Spacer()
                Button {
                    appState.settings.simpleMode = true
                } label: {
                    Label(Strings.Dashboard.simpleMode, systemImage: "hare")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.trailing, 16)
                .padding(.top, 8)
            }

            TabView(selection: $selectedTab) {
                ServerTabView()
                    .tabItem {
                        Label("Server", systemImage: "server.rack")
                    }
                    .tag(0)

                ChatTabView()
                    .tabItem {
                        Label("Chat", systemImage: "bubble.left.and.bubble.right")
                    }
                    .tag(1)

                PerformanceTabView()
                    .tabItem {
                        Label("Performance", systemImage: "chart.xyaxis.line")
                    }
                    .tag(2)

                ClusterTabView()
                    .tabItem {
                        Label("Cluster", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .tag(3)

                ModelTabView()
                    .tabItem {
                        Label("Models", systemImage: "brain")
                    }
                    .tag(4)

                SettingsTabView()
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(5)
            }
        }
        .environment(appState)
    }
}
