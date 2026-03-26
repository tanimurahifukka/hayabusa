import SwiftUI
import Charts

struct ThroughputChart: View {
    let dataPoints: [PerformanceDataPoint]

    var body: some View {
        GroupBox("Throughput") {
            if dataPoints.isEmpty {
                ContentUnavailableView(
                    "No Data",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Start the server to see performance data")
                )
                .frame(height: 200)
            } else {
                Chart(dataPoints) { point in
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("tok/s", point.tokPerSec)
                    )
                    .foregroundStyle(ColorTheme.chartLine)
                    .interpolationMethod(.catmullRom)

                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("tok/s", point.tokPerSec)
                    )
                    .foregroundStyle(ColorTheme.chartArea)
                    .interpolationMethod(.catmullRom)
                }
                .chartYAxisLabel("tok/s")
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisValueLabel(format: .dateTime.minute().second())
                        AxisGridLine()
                    }
                }
                .frame(height: 200)
                .padding()
            }
        }
    }
}
