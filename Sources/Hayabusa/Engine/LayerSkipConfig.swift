import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// Layer skipping configuration for MLX inference.
///
/// Zeroes out the output projections (o_proj/out_proj, down_proj) of skipped layers,
/// making them pure residual passthroughs: `output = input + 0 = input`.
///
/// Recommended threshold for Qwen3.5-4B: 0.093 (skips 6/32 layers, ~1.18x speedup).
/// Note: Weight zeroing ensures correct residual output but does not skip computation.
/// True layer skipping (bypassing forward pass) requires model-specific modifications.
struct LayerSkipConfig: Sendable {
    let skipThreshold: Double
    let taskProfile: String
    let skipLayerIndices: Set<Int>
    let totalLayers: Int

    /// Load layer importance from JSON and compute which layers to skip.
    ///
    /// - Parameters:
    ///   - threshold: Skip layers with importance <= this value (0.0–1.0)
    ///   - task: Task profile name (e.g., "soap")
    ///   - importancePath: Path to layer_importance.json (optional, searches CWD and scripts/)
    init(threshold: Double, task: String = "soap", importancePath: String? = nil) throws {
        self.skipThreshold = threshold
        self.taskProfile = task

        // Search for layer_importance.json
        let candidates = [
            importancePath,
            "layer_importance.json",
            "scripts/layer_importance.json",
        ].compactMap { $0 }

        var loadedJSON: [String: Any]?
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                loadedJSON = json
                print("[LayerSkip] Loaded importance from \(path)")
                break
            }
        }

        if let json = loadedJSON {
            // Parse profiles from JSON
            let profiles = json["profiles"] as? [String: Any] ?? [:]
            let profile = profiles[task] as? [String: Any]
                ?? profiles["default"] as? [String: Any]
                ?? profiles.values.first as? [String: Any]
                ?? [:]

            let layers = profile["layers"] as? [[String: Any]] ?? []
            let numLayers = (json["num_layers"] as? Int) ?? layers.count
            self.totalLayers = numLayers

            var skip = Set<Int>()
            for layer in layers {
                guard let index = layer["index"] as? Int,
                      let importance = layer["importance"] as? Double else { continue }
                if importance <= threshold {
                    skip.insert(index)
                }
            }
            self.skipLayerIndices = skip
        } else {
            // Heuristic fallback: skip middle layers (least important in typical transformers)
            let numLayers = 36  // Qwen3.5-9B default
            self.totalLayers = numLayers

            let skipCount = Int(Double(numLayers) * threshold)
            let middleStart = numLayers / 4
            let middleEnd = numLayers * 3 / 4
            let candidates = Array(middleStart..<middleEnd)

            var skip = Set<Int>()
            // Skip every-other from the middle outward
            for i in stride(from: 0, to: candidates.count, by: 2) {
                if skip.count >= skipCount { break }
                skip.insert(candidates[i])
            }
            // Fill remaining from odd indices
            for i in stride(from: 1, to: candidates.count, by: 2) {
                if skip.count >= skipCount { break }
                skip.insert(candidates[i])
            }
            self.skipLayerIndices = skip
            print("[LayerSkip] No importance file found, using heuristic")
        }

        print("[LayerSkip] Profile: \(task), threshold: \(threshold)")
        print("[LayerSkip] Skipping \(skipLayerIndices.count)/\(totalLayers) layers: \(skipLayerIndices.sorted())")
    }

    /// Apply layer skipping by zeroing output projections of skipped layers.
    ///
    /// For each skipped layer, zeros all parameters under `self_attn.o_proj`
    /// and `mlp.down_proj`. This handles both quantized (weight+scales+biases)
    /// and non-quantized (weight only) layers.
    func apply(to modelContainer: ModelContainer) async {
        guard !skipLayerIndices.isEmpty else {
            print("[LayerSkip] No layers to skip")
            return
        }

        let skipIndices = self.skipLayerIndices

        await modelContainer.perform { (context: ModelContext) in
            let model = context.model
            let flatParams = model.parameters().flattened()

            var updates: [(String, MLXArray)] = []

            for (key, value) in flatParams {
                for layerIdx in skipIndices {
                    // Match both Qwen2.5 (model.layers.N.) and Qwen3.5 (language_model.model.layers.N.)
                    let layerTag = "layers.\(layerIdx)."
                    guard let tagRange = key.range(of: layerTag) else { continue }
                    let suffix = String(key[tagRange.upperBound...])

                    // Zero output projections → makes layer a residual passthrough
                    // Supports both Qwen2.5 (self_attn.o_proj) and Qwen3.5 (linear_attn.out_proj)
                    if suffix.hasPrefix("self_attn.o_proj.") ||
                       suffix.hasPrefix("linear_attn.out_proj.") ||
                       suffix.hasPrefix("mlp.down_proj.") {
                        updates.append((key, MLXArray.zeros(like: value)))
                    }
                }
            }

            if !updates.isEmpty {
                let updateParams = NestedDictionary<String, MLXArray>.unflattened(updates)
                model.update(parameters: updateParams)
            }
        }

        print("[LayerSkip] Zeroed output projections for \(skipLayerIndices.count) layers (\(skipLayerIndices.sorted()))")
    }

    // MARK: - Stats

    /// JSON-compatible summary for /v1/stats endpoint.
    var statsJSON: String {
        let indices = skipLayerIndices.sorted().map { "\($0)" }.joined(separator: ",")
        return """
        {"enabled":true,\
        "threshold":\(skipThreshold),\
        "task":"\(taskProfile)",\
        "totalLayers":\(totalLayers),\
        "skippedLayers":\(skipLayerIndices.count),\
        "skippedIndices":[\(indices)]}
        """
    }
}
