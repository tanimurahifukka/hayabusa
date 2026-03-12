import CLlama

enum SlotPriority: Int, Comparable {
    case low = 0
    case high = 1

    static func < (lhs: SlotPriority, rhs: SlotPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    init(string: String?) {
        switch string?.lowercased() {
        case "high": self = .high
        default: self = .low
        }
    }
}

enum SlotState: String {
    case idle
    case promptEval
    case generating
}

final class SlotInfo {
    let index: Int
    let seqId: llama_seq_id          // == Int32(index)
    var state: SlotState = .idle
    var priority: SlotPriority = .low
    var lastUsedAt: UInt64 = 0       // monotonic clock for LRU
    var currentPos: Int32 = 0        // next write position in sequence

    init(index: Int, seqId: llama_seq_id) {
        self.index = index
        self.seqId = seqId
    }
}

struct SlotHandle {
    let slotIndex: Int
    let seqId: llama_seq_id
}

final class KVCacheManager {
    let maxSlots: Int
    let perSlotContext: UInt32
    private(set) var slots: [SlotInfo]
    private let memory: OpaquePointer  // llama_memory_t
    private var clock: UInt64 = 0

    init(memory: OpaquePointer, maxSlots: Int, perSlotContext: UInt32) {
        self.memory = memory
        self.maxSlots = maxSlots
        self.perSlotContext = perSlotContext
        self.slots = (0..<maxSlots).map { SlotInfo(index: $0, seqId: Int32($0)) }
    }

    /// Acquire a slot: prefer idle, then LRU eviction respecting priority.
    func acquireSlot(priority: SlotPriority) -> SlotHandle? {
        clock += 1

        // 1. Try idle slot (lowest index first)
        if let idle = slots.first(where: { $0.state == .idle }) {
            idle.state = .promptEval
            idle.priority = priority
            idle.lastUsedAt = clock
            idle.currentPos = 0
            return SlotHandle(slotIndex: idle.index, seqId: idle.seqId)
        }

        // 2. LRU eviction
        // First try lower-priority slots, then same-priority. Never evict higher-priority.
        let evictable = slots.filter { $0.priority <= priority }
        guard let victim = evictable.min(by: { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            return a.lastUsedAt < b.lastUsedAt
        }) else {
            return nil
        }

        // Evict: clear KV cache for this sequence
        llama_memory_seq_rm(memory, victim.seqId, -1, -1)
        victim.state = .promptEval
        victim.priority = priority
        victim.lastUsedAt = clock
        victim.currentPos = 0
        return SlotHandle(slotIndex: victim.index, seqId: victim.seqId)
    }

    /// Release a slot: clear KV cache and mark idle.
    func releaseSlot(_ handle: SlotHandle) {
        let slot = slots[handle.slotIndex]
        llama_memory_seq_rm(memory, slot.seqId, -1, -1)
        slot.state = .idle
        slot.priority = .low
        slot.currentPos = 0
    }

    /// Update LRU timestamp.
    func touchSlot(_ handle: SlotHandle) {
        clock += 1
        slots[handle.slotIndex].lastUsedAt = clock
    }

    /// Set slot state.
    func setSlotState(_ handle: SlotHandle, state: SlotState) {
        slots[handle.slotIndex].state = state
    }

    /// Advance the write position for a slot.
    func advancePos(_ handle: SlotHandle, by count: Int32) {
        slots[handle.slotIndex].currentPos += count
    }

    /// Get current write position for a slot.
    func currentPos(for handle: SlotHandle) -> Int32 {
        slots[handle.slotIndex].currentPos
    }

    /// Active (non-idle) slots for continuous batching.
    func activeSlots() -> [(slotIndex: Int, seqId: llama_seq_id, pos: Int32)] {
        slots.filter { $0.state != .idle }.map { ($0.index, $0.seqId, $0.currentPos) }
    }

    /// Acquire an idle slot only (no eviction). Used by the continuous batching scheduler.
    func acquireIdleSlot(priority: SlotPriority) -> SlotHandle? {
        clock += 1
        guard let idle = slots.first(where: { $0.state == .idle }) else {
            return nil
        }
        idle.state = .promptEval
        idle.priority = priority
        idle.lastUsedAt = clock
        idle.currentPos = 0
        return SlotHandle(slotIndex: idle.index, seqId: idle.seqId)
    }

    /// Diagnostic summary.
    func slotSummary() -> [(index: Int, state: String, priority: String, pos: Int32)] {
        slots.map { ($0.index, $0.state.rawValue, $0.priority == .high ? "high" : "low", $0.currentPos) }
    }
}
