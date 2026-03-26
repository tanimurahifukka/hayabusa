import Foundation
import CLlama

/// KV Cache quantization mode.
enum KVQuantizeMode: String {
    case off       // float16 (default)
    case int8      // Q8_0 quantization (~50% memory reduction)

    /// Returns the GGML type for KV cache keys.
    var keyType: ggml_type {
        switch self {
        case .off:  return GGML_TYPE_F16
        case .int8: return GGML_TYPE_Q8_0
        }
    }

    /// Returns the GGML type for KV cache values.
    var valueType: ggml_type {
        switch self {
        case .off:  return GGML_TYPE_F16
        case .int8: return GGML_TYPE_Q8_0
        }
    }

    var description: String {
        switch self {
        case .off:  return "float16 (default)"
        case .int8: return "int8 (Q8_0, ~50% memory savings)"
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
    }

    /// Estimate memory savings compared to float16.
    func estimateMemorySavings(
        nCtx: UInt32,
        nLayers: Int,
        nHeads: Int,
        headDim: Int
    ) -> KVMemoryEstimate {
        let bytesPerElement: Int
        let baselineBytesPerElement = 2 // float16

        switch mode {
        case .off:
            bytesPerElement = 2
        case .int8:
            // Q8_0: 1 byte per element + scale overhead (~2 bytes per 32 elements)
            bytesPerElement = 1
        }

        // KV cache size = 2 (K+V) * n_ctx * n_layers * n_heads * head_dim * bytes_per_element
        let totalElements = 2 * Int(nCtx) * nLayers * nHeads * headDim
        let baselineBytes = totalElements * baselineBytesPerElement
        let quantizedBytes = totalElements * bytesPerElement

        // Account for scale factor overhead in Q8_0 (1 float16 per 32 elements)
        let scaleOverhead = mode == .int8 ? (totalElements / 32) * 2 : 0
        let actualQuantizedBytes = quantizedBytes + scaleOverhead

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
