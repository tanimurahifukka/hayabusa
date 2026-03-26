import SwiftUI

enum ServerState: String, Sendable {
    case stopped
    case starting
    case running
    case error

    var color: Color {
        switch self {
        case .stopped:  .secondary
        case .starting: .orange
        case .running:  .green
        case .error:    .red
        }
    }

    var sfSymbol: String {
        switch self {
        case .stopped:  "stop.circle"
        case .starting: "hourglass"
        case .running:  "checkmark.circle.fill"
        case .error:    "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .stopped:  "Stopped"
        case .starting: "Starting…"
        case .running:  "Running"
        case .error:    "Error"
        }
    }
}
