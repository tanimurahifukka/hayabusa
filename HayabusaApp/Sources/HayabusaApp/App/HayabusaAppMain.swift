import SwiftUI

@main
struct HayabusaAppEntry: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()
    @State private var sparkleUpdater = SparkleUpdater()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(openDashboard: {
                if appState.settings.hasCompletedSetup {
                    openWindow(id: "dashboard")
                } else {
                    openWindow(id: "setup")
                }
                NSApp.activate(ignoringOtherApps: true)
            })
            .environment(appState)
        } label: {
            Label {
                Text("Hayabusa")
            } icon: {
                Image(systemName: appState.serverState == .running ? "bird.fill" : "bird")
            }
        }
        .menuBarExtraStyle(.window)

        Window("Hayabusa Dashboard", id: "dashboard") {
            MainWindow()
                .environment(appState)
                .frame(minWidth: 800, minHeight: 600)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 960, height: 700)

        Window("Hayabusa セットアップ", id: "setup") {
            SetupWizardView()
                .environment(appState)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsTabView()
                .environment(appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep as accessory app (menu bar only, no Dock icon)
        NSApp.setActivationPolicy(.accessory)
    }
}
