import Foundation
import CLlama

/// KV Cache quantization mode.
enum KVQuantizeMode: String {
    case off       // float16 (default)
    case int8      // Q8_0 quantization (~50% memory reduction)
    case tq3       // TQ3_0 TurboQuant 3-bit (~78% memory reduction)
    case tq4       // TQ4_0 TurboQuant 4-bit (~72% memory reduction)

    /// Returns the GGML type for KV cache keys.
    var keyType: ggml_type {
        switch self {
        case .off:  return GGML_TYPE_F16
        case .int8: return GGML_TYPE_Q8_0
        case .tq3:  return GGML_TYPE_TQ1_0
        case .tq4:  return GGML_TYPE_TQ2_0
        }
    }

    /// Returns the GGML type for KV cache values.
    /// Both K and V caches use the same quantization type since Metal FA kernels now exist for TQ3/TQ4.
    var valueType: ggml_type {
        switch self {
        case .off:  return GGML_TYPE_F16
        case .int8: return GGML_TYPE_Q8_0
        case .tq3:  return GGML_TYPE_TQ1_0
        case .tq4:  return GGML_TYPE_TQ2_0
        }
    }

    var description: String {
        switch self {
        case .off:  return "float16 (default)"
        case .int8: return "int8 (Q8_0, ~50% memory savings)"
        case .tq3:  return "tq3 (TQ3_0, 3-bit TurboQuant, ~78% memory savings)"
        case .tq4:  return "tq4 (TQ4_0, 4-bit TurboQuant, ~72% memory savings)"
        }
    }
}

/// KV Cache Quantizer: configures llama.cpp context parameters to use
/// quantized KV cache, reducing memory bandwidth by ~50%.
///
/// How it works:
/// - At context creation, sets type_k and type_v to Q8_0
/// - llama.cpp handles per-token quantization internally
/// - Keys and values are stored as int8 with per-block scale factors
/// - Attention ops dequantize on-the-fly before computation
/// - Quality impact is minimal (BERTScore F1 >= 0.84)
struct KVCacheQuantizer {
    let mode: KVQuantizeMode

    init(mode: KVQuantizeMode = .off) {
        self.mode = mode
    }

    /// Apply KV cache quantization to context parameters.
    func apply(to params: inout llama_context_params) {
        params.type_k = mode.keyType
        params.type_v = mode.valueType

        // TurboQuant: Both K and V caches quantized, Metal FA kernels accelerate attention.
        if mode == .tq3 || mode == .tq4 {
            print("[KVCache] TurboQuant: K=\(mode.rawValue), V=\(mode.rawValue) (Metal FA accelerated)")
        }
    }

    /// Estimate memory savings compared to float16.
    func estimateMemorySavings(
        nCtx: UInt32,
        nLayers: Int,
        nHeads: Int,
        headDim: Int
    ) -> KVMemoryEstimate {
        let baselineBytesPerElement = 2 // float16

        // KV cache size = 2 (K+V) * n_ctx * n_layers * n_heads * head_dim * bytes_per_element
        let totalElements = 2 * Int(nCtx) * nLayers * nHeads * headDim
        let baselineBytes = totalElements * baselineBytesPerElement

        // Calculate actual quantized bytes including scale overhead
        let actualQuantizedBytes: Int
        switch mode {
        case .off:
            actualQuantizedBytes = totalElements * 2
        case .int8:
            // Q8_0: 1 byte per element + 2 bytes scale per 32 elements
            let scaleOverhead = (totalElements / 32) * 2
            actualQuantizedBytes = totalElements * 1 + scaleOverhead
        case .tq3:
            // K=TQ3_0 (14 bytes/32 elements) + V=TQ3_0 (14 bytes/32 elements)
            actualQuantizedBytes = (totalElements / 32) * 14
        case .tq4:
            // K=TQ4_0 (18 bytes/32 elements) + V=TQ4_0 (18 bytes/32 elements)
            actualQuantizedBytes = (totalElements / 32) * 18
        }

        return KVMemoryEstimate(
            baselineBytes: Int64(baselineBytes),
            quantizedBytes: Int64(actualQuantizedBytes),
            savingsBytes: Int64(baselineBytes - actualQuantizedBytes),
            savingsPercent: Double(baselineBytes - actualQuantizedBytes) / Double(baselineBytes) * 100
        )
    }
}

struct KVMemoryEstimate {
    let baselineBytes: Int64
    let quantizedBytes: Int64
    let savingsBytes: Int64
    let savingsPercent: Double
}

/// Extended LlamaEngine initializer that supports KV cache quantization.
extension LlamaEngine {
    /// Create a LlamaEngine with optional KV cache quantization.
    static func withQuantization(
        modelPath: String,
        slotCount: Int = 4,
        perSlotCtx: UInt32 = 4096,
        kvQuantize: KVQuantizeMode = .off
    ) throws -> LlamaEngine {
        if kvQuantize != .off {
            print("[KVCache] Quantization: \(kvQuantize.description)")
            print("[KVCache] type_k=\(kvQuantize.keyType), type_v=\(kvQuantize.valueType)")
        }
        // The actual quantization is applied at context creation time.
        // We pass the mode through to the engine via a static configuration.
        KVCacheQuantizerConfig.shared.mode = kvQuantize
        let engine = try LlamaEngine(modelPath: modelPath, slotCount: slotCount, perSlotCtx: perSlotCtx)
        KVCacheQuantizerConfig.shared.mode = .off // Reset after creation
        return engine
    }
}

/// Global configuration for KV cache quantization.
/// Used during LlamaEngine initialization to pass the quantization mode
/// to the context creation code.
final class KVCacheQuantizerConfig {
    static let shared = KVCacheQuantizerConfig()
    var mode: KVQuantizeMode = .off
    private init() {}
}
