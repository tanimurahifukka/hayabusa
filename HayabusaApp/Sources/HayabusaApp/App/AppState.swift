import SwiftUI

@Observable
final class AppState {
    let settings = AppSettings()
    let processManager = ServerProcessManager()
    let apiClient = APIClient()
    let bonjourScanner = BonjourScanner()

    var showMainWindow = false

    var serverState: ServerState {
        processManager.state
    }

    func startServer() {
        // Update port synchronously before starting
        let port = settings.port
        Task { await apiClient.updatePort(port) }
        processManager.start(settings: settings)
    }

    func stopServer() {
        processManager.stop()
    }
}
