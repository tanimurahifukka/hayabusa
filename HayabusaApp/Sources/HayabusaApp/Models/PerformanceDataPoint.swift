import Foundation

struct PerformanceDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let tokPerSec: Double
    let activeSlots: Int
    let totalSlots: Int
    let rssBytes: Int64
    let freeBytes: Int64
    let pressure: String
}
