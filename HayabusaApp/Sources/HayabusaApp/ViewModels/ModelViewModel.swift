import Foundation
import SwiftUI

struct LocalModel: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let backend: String // "llama" for .gguf, "mlx" for directories

    var sizeFormatted: String {
        Formatters.bytes(size)
    }
}

@Observable
final class ModelViewModel {
    private(set) var localModels: [LocalModel] = []
    let downloader = ModelDownloader()
    var downloadModelId = ""
    var searchPaths: [String] = []

    func scanModels(settings: AppSettings) {
        var models: [LocalModel] = []
        let fm = FileManager.default

        // Scan common locations
        var dirs = [
            NSHomeDirectory() + "/models",
            NSHomeDirectory() + "/.cache/huggingface/hub",
            settings.modelPath.isEmpty ? nil : (settings.modelPath as NSString).deletingLastPathComponent,
        ].compactMap { $0 } + searchPaths

        // Remove duplicates
        dirs = Array(Set(dirs))

        for dir in dirs {
            guard let enumerator = fm.enumerator(atPath: dir) else { continue }
            while let file = enumerator.nextObject() as? String {
                let fullPath = (dir as NSString).appendingPathComponent(file)

                // GGUF files (llama backend)
                if file.hasSuffix(".gguf") {
                    if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                       let size = attrs[.size] as? Int64 {
                        models.append(LocalModel(
                            name: (file as NSString).lastPathComponent,
                            path: fullPath,
                            size: size,
                            backend: "llama"
                        ))
                    }
                    enumerator.skipDescendants()
                }

                // MLX model directories (contain config.json + *.safetensors)
                if file.hasSuffix("config.json") {
                    let modelDir = (fullPath as NSString).deletingLastPathComponent
                    let safetensors = (try? fm.contentsOfDirectory(atPath: modelDir))?.filter { $0.hasSuffix(".safetensors") } ?? []
                    if !safetensors.isEmpty {
                        let totalSize = safetensors.compactMap { f -> Int64? in
                            let p = (modelDir as NSString).appendingPathComponent(f)
                            return (try? fm.attributesOfItem(atPath: p))?[.size] as? Int64
                        }.reduce(0, +)

                        models.append(LocalModel(
                            name: (modelDir as NSString).lastPathComponent,
                            path: modelDir,
                            size: totalSize,
                            backend: "mlx"
                        ))
                    }
                    enumerator.skipDescendants()
                }
            }
        }

        self.localModels = models
    }

    func selectModel(_ model: LocalModel, settings: AppSettings) {
        settings.modelPath = model.path
        settings.backend = model.backend
    }

    func downloadModel(destination: String) {
        guard !downloadModelId.isEmpty else { return }
        downloader.download(modelId: downloadModelId, destination: destination)
    }
}
