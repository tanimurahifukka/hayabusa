import SwiftUI

struct MemoryGauge: View {
    let memory: MemoryInfo?

    var body: some View {
        GroupBox("Memory") {
            if let memory {
                VStack(spacing: 16) {
                    Gauge(value: memory.usageRatio) {
                        Text("Usage")
                    } currentValueLabel: {
                        Text(Formatters.percentage(memory.usageRatio))
                            .font(.title3.bold().monospacedDigit())
                    } minimumValueLabel: {
                        Text("0")
                    } maximumValueLabel: {
                        Text("100%")
                    }
                    .gaugeStyle(.accessoryCircular)
                    .tint(gaugeGradient)
                    .scaleEffect(1.5)
                    .frame(height: 80)

                    VStack(spacing: 4) {
                        LabeledContent("RSS") {
                            Text(Formatters.bytes(memory.rssBytes))
                                .monospacedDigit()
                        }
                        LabeledContent("Free") {
                            Text(Formatters.bytes(memory.freeEstimate))
                                .monospacedDigit()
                        }
                        LabeledContent("Total") {
                            Text(Formatters.bytes(memory.totalPhysical))
                                .monospacedDigit()
                        }
                        LabeledContent("Pressure") {
                            Text(memory.pressure.capitalized)
                                .foregroundStyle(pressureColor)
                        }
                    }
                    .font(.caption)
                }
                .padding()
            } else {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "memorychip",
                    description: Text("Server not running")
                )
            }
        }
    }

    private var gaugeGradient: Gradient {
        Gradient(colors: [.green, .yellow, .orange, .red])
    }

    private var pressureColor: Color {
        guard let memory else { return .secondary }
        switch memory.pressureLevel {
        case .normal: return .green
        case .low: return .yellow
        case .critical: return .orange
        case .emergency: return .red
        case .unknown: return .secondary
        }
    }
}
