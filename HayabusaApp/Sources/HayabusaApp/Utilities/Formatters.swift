import Foundation

enum Formatters {
    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: value)
    }

    static func bytes(_ value: Int) -> String {
        bytes(Int64(value))
    }

    static func tokPerSec(_ value: Double) -> String {
        String(format: "%.1f tok/s", value)
    }

    static func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        } else if seconds < 3600 {
            let m = Int(seconds) / 60
            let s = Int(seconds) % 60
            return "\(m)m \(s)s"
        } else {
            let h = Int(seconds) / 3600
            let m = (Int(seconds) % 3600) / 60
            return "\(h)h \(m)m"
        }
    }

    static func port(_ value: Int) -> String {
        ":\(value)"
    }
}
