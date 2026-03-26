import Foundation

struct SlotInfo: Decodable, Identifiable {
    let index: Int
    let state: String
    let priority: String
    let pos: Int

    var id: Int { index }

    var isActive: Bool {
        state != "idle" && state != "empty"
    }
}
