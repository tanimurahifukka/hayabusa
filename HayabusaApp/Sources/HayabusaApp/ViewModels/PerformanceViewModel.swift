import Foundation
import SwiftUI

@Observable
final class PerformanceViewModel {
    private(set) var dataPoints: [PerformanceDataPoint] = []
    private(set) var currentMemory: MemoryInfo?
    private(set) var currentSlots: [SlotInfo] = []

    /// Peak tok/s seen in this session
    private(set) var peakTokPerSec: Double = 0
    /// Last non-zero tok/s
    private(set) var lastActiveTokPerSec: Double = 0

    private var timer: Timer?
    private let maxPoints = 300
    /// Previous total pos across all slots (for delta calculation)
    private var prevTotalPos: Int = 0
    /// Whether we had active slots in the previous tick
    private var prevHadActive: Bool = false

    var latestTokPerSec: Double {
        dataPoints.last?.tokPerSec ?? 0
    }

    var displayTokPerSec: Double {
        let current = latestTokPerSec
        return current > 0 ? current : lastActiveTokPerSec
    }

    var activeSlotCount: Int {
        currentSlots.filter(\.isActive).count
    }

    var totalSlotCount: Int {
        currentSlots.count
    }

    func startPolling(apiClient: APIClient) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.poll(apiClient: apiClient)
            }
        }
        Task { @MainActor in
            await poll(apiClient: apiClient)
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    @MainActor
    private func poll(apiClient: APIClient) async {
        // Fetch slots
        let slots: [SlotInfo]
        do {
            slots = try await apiClient.slots()
        } catch {
            return
        }
        self.currentSlots = slots

        // Fetch memory (optional)
        let memory: MemoryInfo?
        do {
            memory = try await apiClient.memory()
            self.currentMemory = memory
        } catch {
            memory = nil
        }

        // Calculate tok/s from slot position deltas
        let activeSlots = slots.filter(\.isActive)
        let activeCount = activeSlots.count
        let currentTotalPos = slots.reduce(0) { $0 + $1.pos }

        let tokPerSec: Double
        if activeCount > 0 && prevHadActive {
            // Both ticks have active slots → delta is meaningful
            let delta = currentTotalPos - prevTotalPos
            tokPerSec = delta > 0 ? Double(delta) : 0
        } else if activeCount > 0 && !prevHadActive {
            // Just started generating → skip first tick (includes prompt eval)
            tokPerSec = 0
        } else {
            tokPerSec = 0
        }

        prevTotalPos = currentTotalPos
        prevHadActive = activeCount > 0

        // Track peaks
        if tokPerSec > 0 {
            lastActiveTokPerSec = tokPerSec
            if tokPerSec > peakTokPerSec {
                peakTokPerSec = tokPerSec
            }
        }

        let point = PerformanceDataPoint(
            timestamp: Date(),
            tokPerSec: tokPerSec,
            activeSlots: activeCount,
            totalSlots: slots.count,
            rssBytes: memory?.rssBytes ?? 0,
            freeBytes: memory?.freeEstimate ?? 0,
            pressure: memory?.pressure ?? "unknown"
        )

        dataPoints.append(point)
        if dataPoints.count > maxPoints {
            dataPoints.removeFirst(dataPoints.count - maxPoints)
        }
    }
}
