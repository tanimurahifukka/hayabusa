import Foundation

@Observable
final class AppSettings {
    // Server
    var modelPath: String {
        didSet { UserDefaults.standard.set(modelPath, forKey: "modelPath") }
    }
    var backend: String {
        didSet { UserDefaults.standard.set(backend, forKey: "backend") }
    }
    var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "port") }
    }
    var slotCount: Int {
        didSet { UserDefaults.standard.set(slotCount, forKey: "slotCount") }
    }
    var ctxPerSlot: Int {
        didSet { UserDefaults.standard.set(ctxPerSlot, forKey: "ctxPerSlot") }
    }

    // MLX
    var maxMemoryGB: Double {
        didSet { UserDefaults.standard.set(maxMemoryGB, forKey: "maxMemoryGB") }
    }
    var maxContext: Int {
        didSet { UserDefaults.standard.set(maxContext, forKey: "maxContext") }
    }

    // Cluster
    var clusterEnabled: Bool {
        didSet { UserDefaults.standard.set(clusterEnabled, forKey: "clusterEnabled") }
    }
    var peers: [String] {
        didSet { UserDefaults.standard.set(peers, forKey: "peers") }
    }
    var spilloverThreshold: Double {
        didSet { UserDefaults.standard.set(spilloverThreshold, forKey: "spilloverThreshold") }
    }

    // App
    var launchAtLogin: Bool {
        didSet { UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin") }
    }
    var autoStartServer: Bool {
        didSet { UserDefaults.standard.set(autoStartServer, forKey: "autoStartServer") }
    }
    var hasCompletedSetup: Bool {
        didSet { UserDefaults.standard.set(hasCompletedSetup, forKey: "hasCompletedSetup") }
    }
    var hayabusaBinaryPath: String {
        didSet { UserDefaults.standard.set(hayabusaBinaryPath, forKey: "hayabusaBinaryPath") }
    }

    // Simple mode
    var simpleMode: Bool {
        didSet { UserDefaults.standard.set(simpleMode, forKey: "simpleMode") }
    }
    var selectedModelId: String {
        didSet { UserDefaults.standard.set(selectedModelId, forKey: "selectedModelId") }
    }

    init() {
        let defaults = UserDefaults.standard
        self.modelPath = defaults.string(forKey: "modelPath") ?? ""
        self.backend = defaults.string(forKey: "backend") ?? "llama"
        self.port = defaults.integer(forKey: "port").nonZero ?? 8080
        self.slotCount = defaults.integer(forKey: "slotCount").nonZero ?? 4
        self.ctxPerSlot = defaults.integer(forKey: "ctxPerSlot").nonZero ?? 4096
        self.maxMemoryGB = defaults.double(forKey: "maxMemoryGB").nonZeroDouble ?? 14.0
        self.maxContext = defaults.integer(forKey: "maxContext").nonZero ?? 2048
        self.clusterEnabled = defaults.bool(forKey: "clusterEnabled")
        self.peers = defaults.stringArray(forKey: "peers") ?? []
        self.spilloverThreshold = defaults.double(forKey: "spilloverThreshold").nonZeroDouble ?? 0.8
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        self.autoStartServer = defaults.bool(forKey: "autoStartServer")
        self.hasCompletedSetup = defaults.bool(forKey: "hasCompletedSetup")
        self.hayabusaBinaryPath = defaults.string(forKey: "hayabusaBinaryPath") ?? ""
        self.simpleMode = defaults.object(forKey: "simpleMode") == nil ? true : defaults.bool(forKey: "simpleMode")
        self.selectedModelId = defaults.string(forKey: "selectedModelId") ?? ""
    }
}

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

private extension Double {
    var nonZeroDouble: Double? { self == 0 ? nil : self }
}
