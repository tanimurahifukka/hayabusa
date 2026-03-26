import SwiftUI

struct SlotUtilizationView: View {
    let slots: [SlotInfo]

    var body: some View {
        GroupBox("Slot Utilization") {
            if slots.isEmpty {
                ContentUnavailableView(
                    "No Slots",
                    systemImage: "square.grid.2x2",
                    description: Text("Server not running")
                )
                .frame(height: 80)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(slots.count, 8)), spacing: 8) {
                    ForEach(slots) { slot in
                        SlotCell(slot: slot)
                    }
                }
                .padding()
            }
        }
    }
}

private struct SlotCell: View {
    let slot: SlotInfo

    var body: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 6)
                .fill(slotColor)
                .frame(height: 40)
                .overlay {
                    Text("#\(slot.index)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.white)
                }

            Text(slot.state)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var slotColor: Color {
        switch slot.state {
        case "idle", "empty":
            return ColorTheme.slotIdle
        case "generating":
            return ColorTheme.slotActive
        case "promptEval", "pendingPromptEval":
            return ColorTheme.slotProcessing
        default:
            return ColorTheme.slotIdle
        }
    }
}
