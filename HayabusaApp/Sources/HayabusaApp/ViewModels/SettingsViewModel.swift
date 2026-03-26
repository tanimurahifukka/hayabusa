import Foundation
import SwiftUI

@Observable
final class SettingsViewModel {
    var portText: String = ""
    var slotsText: String = ""
    var ctxPerSlotText: String = ""
    var maxMemoryText: String = ""
    var maxContextText: String = ""
    var spilloverText: String = ""
    var validationErrors: [String: String] = [:]

    func load(from settings: AppSettings) {
        portText = String(settings.port)
        slotsText = String(settings.slotCount)
        ctxPerSlotText = String(settings.ctxPerSlot)
        maxMemoryText = String(format: "%.0f", settings.maxMemoryGB)
        maxContextText = String(settings.maxContext)
        spilloverText = String(format: "%.2f", settings.spilloverThreshold)
    }

    func save(to settings: AppSettings) -> Bool {
        validationErrors.removeAll()

        guard let port = Int(portText), (1024...65535).contains(port) else {
            validationErrors["port"] = "Port must be 1024-65535"
            return false
        }
        guard let slots = Int(slotsText), (1...64).contains(slots) else {
            validationErrors["slots"] = "Slots must be 1-64"
            return false
        }
        guard let ctx = Int(ctxPerSlotText), (256...131072).contains(ctx) else {
            validationErrors["ctxPerSlot"] = "Context must be 256-131072"
            return false
        }
        guard let mem = Double(maxMemoryText), (1...512).contains(mem) else {
            validationErrors["maxMemory"] = "Memory must be 1-512 GB"
            return false
        }
        guard let maxCtx = Int(maxContextText), (256...131072).contains(maxCtx) else {
            validationErrors["maxContext"] = "Context must be 256-131072"
            return false
        }
        guard let spillover = Double(spilloverText), (0...1).contains(spillover) else {
            validationErrors["spillover"] = "Spillover must be 0.0-1.0"
            return false
        }

        settings.port = port
        settings.slotCount = slots
        settings.ctxPerSlot = ctx
        settings.maxMemoryGB = mem
        settings.maxContext = maxCtx
        settings.spilloverThreshold = spillover
        return true
    }
}
