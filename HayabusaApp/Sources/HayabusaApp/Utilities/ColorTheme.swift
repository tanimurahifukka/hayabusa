import SwiftUI

enum ColorTheme {
    static let accent = Color.blue
    static let serverRunning = Color.green
    static let serverStopped = Color.secondary
    static let serverError = Color.red

    static let nodeHealthy = Color.green
    static let nodeLoaded = Color.yellow
    static let nodeUnhealthy = Color.red

    static let chartLine = Color.blue
    static let chartArea = Color.blue.opacity(0.15)
    static let chartMemory = Color.orange

    static let slotIdle = Color.gray.opacity(0.3)
    static let slotActive = Color.green
    static let slotProcessing = Color.blue

    static func nodeColor(load: Double, healthy: Bool) -> Color {
        guard healthy else { return nodeUnhealthy }
        if load < 0.5 { return nodeHealthy }
        if load < 0.85 { return nodeLoaded }
        return nodeUnhealthy
    }
}
