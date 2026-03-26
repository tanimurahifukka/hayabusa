import Foundation

struct MemoryInfo: Decodable {
    let totalPhysical: Int64
    let rssBytes: Int64
    let freeEstimate: Int64
    let activeSlots: Int
    let pressure: String
    let slots: Int?

    var usageRatio: Double {
        guard totalPhysical > 0 else { return 0 }
        return Double(rssBytes) / Double(totalPhysical)
    }

    var pressureLevel: PressureLevel {
        PressureLevel(rawValue: pressure) ?? .unknown
    }

    enum PressureLevel: String {
        case normal
        case low
        case critical
        case emergency
        case unknown
    }
}
