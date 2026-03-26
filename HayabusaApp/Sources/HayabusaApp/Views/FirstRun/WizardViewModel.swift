import Foundation
import SwiftUI

@Observable
final class WizardViewModel {
    enum Step: Int, CaseIterable {
        case welcome = 0
        case modelSelect = 1
        case download = 2
        case cluster = 3
        case complete = 4
    }

    enum ModelTier: String, CaseIterable {
        case light
        case recommended
        case high

        var huggingFaceId: String {
            switch self {
            case .light:      return "mlx-community/Qwen3.5-3B-Instruct-4bit"
            case .recommended: return "mlx-community/Qwen3.5-8B-Instruct-4bit"
            case .high:       return "mlx-community/Qwen3.5-32B-Instruct-4bit"
            }
        }

        var displayName: String {
            switch self {
            case .light:      return Strings.Wizard.modelLightName
            case .recommended: return Strings.Wizard.modelRecommendedName
            case .high:       return Strings.Wizard.modelHighName
            }
        }

        var description: String {
            switch self {
            case .light:      return Strings.Wizard.modelLightDescription
            case .recommended: return Strings.Wizard.modelRecommendedDescription
            case .high:       return Strings.Wizard.modelHighDescription
            }
        }

        var detail: String {
            switch self {
            case .light:      return Strings.Wizard.modelLightDetail
            case .recommended: return Strings.Wizard.modelRecommendedDetail
            case .high:       return Strings.Wizard.modelHighDetail
            }
        }

        var memoryInfo: String {
            switch self {
            case .light:      return Strings.Wizard.modelLightMemory
            case .recommended: return Strings.Wizard.modelRecommendedMemory
            case .high:       return Strings.Wizard.modelHighMemory
            }
        }

        var badge: String? {
            self == .recommended ? Strings.Wizard.modelRecommendedBadge : nil
        }
    }

    enum ClusterChoice {
        case standalone
        case connect
    }

    /// Represents a locally installed model found on disk
    struct LocalModel: Identifiable, Hashable {
        let id: String          // unique key (path)
        let name: String        // display name
        let path: String        // full path
        let backend: String     // "llama" or "mlx"
        let sizeBytes: Int64    // file/dir size

        var sizeDisplay: String {
            let gb = Double(sizeBytes) / 1_073_741_824
            if gb >= 1.0 {
                return String(format: "%.1f GB", gb)
            }
            let mb = Double(sizeBytes) / 1_048_576
            return String(format: "%.0f MB", mb)
        }
    }

    // MARK: - Selection mode

    enum ModelSelectionMode {
        case tier       // download new model
        case local      // use installed model
    }

    var selectionMode: ModelSelectionMode = .tier
    var localModels: [LocalModel] = []
    var selectedLocalModel: LocalModel?

    var currentStep: Step = .welcome
    var selectedModel: ModelTier = .recommended
    var clusterChoice: ClusterChoice = .standalone
    var selectedPeerIds: Set<String> = []
    var serverStarted = false
    var downloadError: String?

    private let downloader = ModelDownloader()

    var isDownloading: Bool { downloader.isDownloading }
    var downloadProgress: Double { downloader.progress }
    var downloadCurrentFile: String { downloader.currentFile }
    var downloaderError: String? { downloader.error }
    var isDownloadComplete: Bool { downloadProgress >= 1.0 && !isDownloading }

    var stepCount: Int { Step.allCases.count }

    /// Whether the selected local model or download is ready
    var useLocalModel: Bool {
        selectionMode == .local && selectedLocalModel != nil
    }

    func goNext() {
        // If using local model, skip download step
        if currentStep == .modelSelect && useLocalModel {
            currentStep = .cluster
            return
        }
        guard let nextStep = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = nextStep
    }

    func goBack() {
        // If on cluster and came from local model selection, go back to modelSelect
        if currentStep == .cluster && useLocalModel {
            currentStep = .modelSelect
            return
        }
        guard let prevStep = Step(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prevStep
    }

    func canGoNext() -> Bool {
        switch currentStep {
        case .welcome:
            return true
        case .modelSelect:
            if selectionMode == .local {
                return selectedLocalModel != nil
            }
            return true
        case .download:
            return isDownloadComplete
        case .cluster:
            if clusterChoice == .connect {
                return !selectedPeerIds.isEmpty
            }
            return true
        case .complete:
            return false
        }
    }

    // MARK: - Scan local models

    func scanLocalModels() {
        var found: [LocalModel] = []
        let fm = FileManager.default

        // Search paths for GGUF files
        let searchPaths = [
            fm.homeDirectoryForCurrentUser.path + "/.hayabusa/models",
            fm.homeDirectoryForCurrentUser.path + "/Desktop/Lang/hayabusa/models",
            fm.homeDirectoryForCurrentUser.path + "/Projects/BLAZING/engines/hayabusa/models",
            fm.homeDirectoryForCurrentUser.path + "/models",
        ]

        for dir in searchPaths {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in contents {
                let fullPath = (dir as NSString).appendingPathComponent(item)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { continue }

                if item.hasSuffix(".gguf") && !isDir.boolValue {
                    // GGUF file
                    let attrs = try? fm.attributesOfItem(atPath: fullPath)
                    let size = attrs?[.size] as? Int64 ?? 0
                    // Skip tiny vocab-only files
                    guard size > 50_000_000 else { continue }
                    let name = (item as NSString).deletingPathExtension
                    found.append(LocalModel(
                        id: fullPath,
                        name: name,
                        path: fullPath,
                        backend: "llama",
                        sizeBytes: size
                    ))
                } else if isDir.boolValue {
                    // Check if it's an MLX model directory (has config.json + *.safetensors)
                    let configPath = (fullPath as NSString).appendingPathComponent("config.json")
                    if fm.fileExists(atPath: configPath) {
                        let size = directorySize(path: fullPath)
                        guard size > 50_000_000 else { continue }
                        found.append(LocalModel(
                            id: fullPath,
                            name: item,
                            path: fullPath,
                            backend: "mlx",
                            sizeBytes: size
                        ))
                    }
                }
            }
        }

        // Sort by name
        localModels = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        // Auto-select if only one
        if localModels.count == 1 {
            selectedLocalModel = localModels.first
        }

        // If local models found, default to local mode
        if !localModels.isEmpty {
            selectionMode = .local
        }
    }

    private func directorySize(path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let file = enumerator.nextObject() as? String {
            let fullPath = (path as NSString).appendingPathComponent(file)
            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        return total
    }

    // MARK: - Download

    func startDownload(settings: AppSettings) {
        downloadError = nil
        let modelId = selectedModel.huggingFaceId
        let destination = modelDownloadPath(for: modelId)

        // Create destination directory
        try? FileManager.default.createDirectory(
            atPath: destination,
            withIntermediateDirectories: true
        )

        downloader.download(modelId: modelId, destination: destination)
    }

    func cancelDownload() {
        downloader.cancel()
    }

    func retryDownload(settings: AppSettings) {
        startDownload(settings: settings)
    }

    // MARK: - Apply settings

    func applySettings(to settings: AppSettings) {
        if useLocalModel, let local = selectedLocalModel {
            settings.modelPath = local.path
            settings.backend = local.backend
            settings.selectedModelId = local.name
        } else {
            let modelId = selectedModel.huggingFaceId
            let destination = modelDownloadPath(for: modelId)
            settings.modelPath = destination
            settings.backend = "mlx"
            settings.selectedModelId = selectedModel.rawValue
        }

        if clusterChoice == .connect {
            settings.clusterEnabled = true
        } else {
            settings.clusterEnabled = false
        }

        settings.hasCompletedSetup = true
    }

    func applyClusterPeers(to settings: AppSettings, nodes: [DiscoveredNode]) {
        let selectedNodes = nodes.filter { selectedPeerIds.contains($0.id) }
        settings.peers = selectedNodes.map(\.peerString)
    }

    // MARK: - Helpers

    private func modelDownloadPath(for modelId: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let safeName = modelId.replacingOccurrences(of: "/", with: "_")
        return "\(home)/.hayabusa/models/\(safeName)"
    }
}
