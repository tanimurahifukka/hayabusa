import SwiftUI

struct StatusIndicatorView: View {
    let tokPerSec: Double

    private enum Level {
        case comfortable
        case moderate
        case busy

        var label: String {
            switch self {
            case .comfortable: return Strings.Dashboard.statusComfortable
            case .moderate:    return Strings.Dashboard.statusModerate
            case .busy:        return Strings.Dashboard.statusBusy
            }
        }

        var color: Color {
            switch self {
            case .comfortable: return .green
            case .moderate:    return .yellow
            case .busy:        return .red
            }
        }

        var icon: String {
            switch self {
            case .comfortable: return "checkmark.circle.fill"
            case .moderate:    return "exclamationmark.circle.fill"
            case .busy:        return "xmark.circle.fill"
            }
        }
    }

    private var level: Level {
        if tokPerSec > 20 { return .comfortable }
        if tokPerSec > 5  { return .moderate }
        return .busy
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: level.icon)
                .foregroundStyle(level.color)
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(level.label)
                    .font(.headline)
                    .foregroundStyle(level.color)
                Text(String(format: "%.1f %@", tokPerSec, Strings.Dashboard.tokensPerSecond))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(level.color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
