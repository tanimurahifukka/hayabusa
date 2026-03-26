import Foundation
import SwiftUI

@Observable
final class ServerViewModel {
    var isHealthy = false
    private var healthTimer: Timer?

    func startMonitoring(appState: AppState) {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if appState.serverState == .running {
                    do {
                        self.isHealthy = try await appState.apiClient.health()
                    } catch {
                        self.isHealthy = false
                    }
                } else {
                    self.isHealthy = false
                }
            }
        }
    }

    func stopMonitoring() {
        healthTimer?.invalidate()
        healthTimer = nil
    }
}
