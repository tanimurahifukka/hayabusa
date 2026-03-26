import Foundation
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - Configuration

struct GenomeConfig: Sendable {
    let outputPath: String
    let sparsityThreshold: Float

    init(outputPath: String = "genome.json", sparsityThreshold: Float = 1e-5) {
        self.outputPath = outputPath
        self.sparsityThreshold = sparsityThreshold
    }
}

// MARK: - Report Structs

struct LayerGenomeMetrics: Codable {
    let layerIndex: Int
    let layerType: String
    let meanActivation: Float
    let l2Norm: Float
    let sparsity: Float
    let attentionEntropy: Float
}

struct GenomeSummary: Codable {
    let meanActivationRange: [Float]
    let avgSparsity: Float
    let avgL2Norm: Float
    let mostActiveLayer: Int
    let leastActiveLayer: Int
}

struct GenomeReport: Codable {
    let modelName: String
    let timestamp: String
    let inputTokens: Int
    let totalLayers: Int
    let totalParameters: Int
    let layers: [LayerGenomeMetrics]
    let summary: GenomeSummary
}

// MARK: - Collector

enum GenomeCollector {

    static func collect(
        from modelContainer: ModelContainer,
        modelName: String,
        config: GenomeConfig
    ) async throws {
        print("[Genome] Starting weight-based genome collection...")

        let report: GenomeReport = await modelContainer.perform { context in
            let model = context.model
            let flatParams = model.parameters().flattened()

            // Discover layers: group keys by layer index
            var layerKeys: [Int: [(String, MLXArray)]] = [:]
            var totalParams = 0

            for (key, value) in flatParams {
                totalParams += value.size
                guard let layerIndex = parseLayerIndex(from: key) else { continue }
                layerKeys[layerIndex, default: []].append((key, value))
            }

            let sortedIndices = layerKeys.keys.sorted()
            print("[Genome] Found \(sortedIndices.count) layers, \(totalParams) total parameters")

            var layerMetrics: [LayerGenomeMetrics] = []

            for layerIndex in sortedIndices {
                guard let params = layerKeys[layerIndex] else { continue }

                let layerType = detectLayerType(params: params)
                let metrics = computeLayerMetrics(
                    layerIndex: layerIndex,
                    layerType: layerType,
                    params: params,
                    sparsityThreshold: config.sparsityThreshold
                )
                layerMetrics.append(metrics)

                if layerIndex % 10 == 0 {
                    print("[Genome] Processed layer \(layerIndex)/\(sortedIndices.count - 1)")
                }
            }

            let summary = buildSummary(from: layerMetrics)

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]

            return GenomeReport(
                modelName: modelName,
                timestamp: formatter.string(from: Date()),
                inputTokens: 0,
                totalLayers: sortedIndices.count,
                totalParameters: totalParams,
                layers: layerMetrics,
                summary: summary
            )
        }

        // Write JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let url = URL(fileURLWithPath: config.outputPath)
        try data.write(to: url)

        print("[Genome] Wrote \(report.layers.count) layers to \(config.outputPath)")
        print("[Genome] Most active: layer \(report.summary.mostActiveLayer), Least active: layer \(report.summary.leastActiveLayer)")
        print("[Genome] Avg sparsity: \(report.summary.avgSparsity), Avg L2: \(report.summary.avgL2Norm)")
    }

    // MARK: - Key Parsing

    private static func parseLayerIndex(from key: String) -> Int? {
        // Match "layers.N." pattern anywhere in the key
        guard let range = key.range(of: #"layers\.(\d+)\."#, options: .regularExpression) else {
            return nil
        }
        let matched = String(key[range])
        let parts = matched.split(separator: ".")
        guard parts.count >= 2, let idx = Int(parts[1]) else { return nil }
        return idx
    }

    // MARK: - Layer Type Detection

    private static func detectLayerType(params: [(String, MLXArray)]) -> String {
        for (key, _) in params {
            if key.contains("self_attn.") { return "attention" }
            if key.contains("linear_attn.") { return "linear_attn" }
        }
        return "decoder"
    }

    // MARK: - Per-Layer Metrics

    private static func computeLayerMetrics(
        layerIndex: Int,
        layerType: String,
        params: [(String, MLXArray)],
        sparsityThreshold: Float
    ) -> LayerGenomeMetrics {
        // Build a lookup for quick access
        var paramMap: [String: MLXArray] = [:]
        for (key, value) in params {
            // Extract suffix after "layers.N."
            if let range = key.range(of: #"layers\.\d+\."#, options: .regularExpression) {
                let suffix = String(key[range.upperBound...])
                paramMap[suffix] = value
            }
        }

        let meanAct = computeMeanActivation(paramMap: paramMap, layerType: layerType)
        let l2 = computeL2Norm(paramMap: paramMap)
        let sparsity = computeSparsity(paramMap: paramMap, threshold: sparsityThreshold)
        let entropy = computeAttentionEntropy(paramMap: paramMap, layerType: layerType)

        return LayerGenomeMetrics(
            layerIndex: layerIndex,
            layerType: layerType,
            meanActivation: meanAct,
            l2Norm: l2,
            sparsity: sparsity,
            attentionEntropy: entropy
        )
    }

    /// Mean absolute value of output projection weights as a proxy for activation magnitude.
    private static func computeMeanActivation(paramMap: [String: MLXArray], layerType: String) -> Float {
        // Find output projection weights (prefer scales for quantized)
        let outputKeys: [String]
        switch layerType {
        case "attention":
            outputKeys = ["self_attn.o_proj.scales", "self_attn.o_proj.weight",
                          "mlp.down_proj.scales", "mlp.down_proj.weight"]
        case "linear_attn":
            outputKeys = ["linear_attn.out_proj.scales", "linear_attn.out_proj.weight",
                          "mlp.down_proj.scales", "mlp.down_proj.weight"]
        default:
            outputKeys = ["mlp.down_proj.scales", "mlp.down_proj.weight"]
        }

        // Use first available key (scales preferred over weight for quantized)
        for key in outputKeys {
            if let arr = paramMap[key] {
                let result = MLX.mean(MLX.abs(arr))
                eval(result)
                return result.item(Float.self)
            }
        }
        return 0
    }

    /// L2 norm across all layer parameters. For quantized: sqrt(sum(scales^2)) * sqrt(groupSize).
    private static func computeL2Norm(paramMap: [String: MLXArray]) -> Float {
        var sumSq = MLXArray(Float(0))
        var hasQuantized = false

        for (key, value) in paramMap {
            if key.hasSuffix(".scales") {
                hasQuantized = true
                let sq = MLX.sum(value * value)
                sumSq = sumSq + sq
            } else if key.hasSuffix(".weight") {
                // Only use weight if no scales sibling exists
                let scalesKey = key.replacingOccurrences(of: ".weight", with: ".scales")
                if paramMap[scalesKey] == nil {
                    let sq = MLX.sum(value * value)
                    sumSq = sumSq + sq
                }
            }
        }

        eval(sumSq)
        var norm = sqrt(sumSq.item(Float.self))

        // For quantized models, scale by sqrt(groupSize) (typically 32 or 64)
        if hasQuantized {
            let groupSize: Float = 32
            norm *= sqrt(groupSize)
        }

        return norm
    }

    /// Fraction of near-zero elements. For quantized: fraction of near-zero scale groups.
    private static func computeSparsity(paramMap: [String: MLXArray], threshold: Float) -> Float {
        var totalElements = 0
        var nearZeroElements = 0

        for (key, value) in paramMap {
            if key.hasSuffix(".scales") {
                let absVal = MLX.abs(value)
                let threshArr = MLXArray(threshold)
                let mask = absVal .< threshArr
                let nzCount = MLX.sum(mask)
                eval(nzCount)
                nearZeroElements += nzCount.item(Int.self)
                totalElements += value.size
            } else if key.hasSuffix(".weight") {
                let scalesKey = key.replacingOccurrences(of: ".weight", with: ".scales")
                if paramMap[scalesKey] == nil {
                    // Non-quantized weight
                    let absVal = MLX.abs(value)
                    let threshArr = MLXArray(threshold)
                    let mask = absVal .< threshArr
                    let nzCount = MLX.sum(mask)
                    eval(nzCount)
                    nearZeroElements += nzCount.item(Int.self)
                    totalElements += value.size
                }
            }
        }

        guard totalElements > 0 else { return 0 }
        return Float(nearZeroElements) / Float(totalElements)
    }

    /// Attention entropy proxy: Frobenius norm ratio of Q to K projections, mapped through -log2.
    private static func computeAttentionEntropy(paramMap: [String: MLXArray], layerType: String) -> Float {
        let (numKey, denomKey): (String, String)
        switch layerType {
        case "attention":
            // Try scales first, then weight
            if paramMap["self_attn.q_proj.scales"] != nil {
                numKey = "self_attn.q_proj.scales"
                denomKey = "self_attn.k_proj.scales"
            } else {
                numKey = "self_attn.q_proj.weight"
                denomKey = "self_attn.k_proj.weight"
            }
        case "linear_attn":
            // Qwen3.5 uses in_proj_qkv, Qwen3Next uses in_proj_qkvz
            let inProjCandidates = ["linear_attn.in_proj_qkv.scales", "linear_attn.in_proj_qkvz.scales",
                                    "linear_attn.in_proj_qkv.weight", "linear_attn.in_proj_qkvz.weight"]
            let outProjCandidates = ["linear_attn.out_proj.scales", "linear_attn.out_proj.weight"]
            let foundIn = inProjCandidates.first { paramMap[$0] != nil }
            let foundOut = outProjCandidates.first { paramMap[$0] != nil }
            if let foundIn, let foundOut {
                numKey = foundIn
                denomKey = foundOut
            } else {
                return 0
            }
        default:
            return 0
        }

        guard let qArr = paramMap[numKey], let kArr = paramMap[denomKey] else { return 0 }

        let qNorm = MLX.sqrt(MLX.sum(qArr * qArr))
        let kNorm = MLX.sqrt(MLX.sum(kArr * kArr))
        eval(qNorm)
        eval(kNorm)

        let qVal = qNorm.item(Float.self)
        let kVal = kNorm.item(Float.self)

        guard kVal > 0 else { return 0 }
        let ratio = qVal / kVal
        guard ratio > 0 else { return 0 }

        return -log2(ratio)
    }

    // MARK: - Summary

    private static func buildSummary(from layers: [LayerGenomeMetrics]) -> GenomeSummary {
        guard !layers.isEmpty else {
            return GenomeSummary(
                meanActivationRange: [0, 0],
                avgSparsity: 0,
                avgL2Norm: 0,
                mostActiveLayer: 0,
                leastActiveLayer: 0
            )
        }

        let activations = layers.map { $0.meanActivation }
        let minAct = activations.min() ?? 0
        let maxAct = activations.max() ?? 0
        let avgSparsity = layers.map { $0.sparsity }.reduce(0, +) / Float(layers.count)
        let avgL2 = layers.map { $0.l2Norm }.reduce(0, +) / Float(layers.count)

        let mostActive = layers.max(by: { $0.meanActivation < $1.meanActivation })?.layerIndex ?? 0
        let leastActive = layers.min(by: { $0.meanActivation < $1.meanActivation })?.layerIndex ?? 0

        return GenomeSummary(
            meanActivationRange: [minAct, maxAct],
            avgSparsity: avgSparsity,
            avgL2Norm: avgL2,
            mostActiveLayer: mostActive,
            leastActiveLayer: leastActive
        )
    }
}
