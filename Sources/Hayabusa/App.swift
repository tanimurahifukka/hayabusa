import Foundation
import Hummingbird

@main
struct HayabusaApp {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())

        // Parse CLI arguments
        var modelPath: String?
        var slotCount = 4
        var ctxPerSlot: UInt32 = 4096
        var backend = "llama"
        var maxMemoryGB: Double?
        var maxContext: Int?
        var clusterMode = false
        var peers: [String] = []
        var spilloverThreshold: Double = 0.8
        var draftModelPath: String?
        var targetModelPath: String?
        var speculativeTokens: Int = 4
        var kvQuantize: KVQuantizeMode = .off
        var layerSkipThreshold: Double?
        var layerSkipTask: String = "soap"
        var vllmEndpoint: String?
        var genomeMode = false
        var genomeOutputPath: String?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--slots":
                i += 1
                if i < args.count, let n = Int(args[i]) { slotCount = n }
            case "--ctx-per-slot":
                i += 1
                if i < args.count, let n = UInt32(args[i]) { ctxPerSlot = n }
            case "--backend":
                i += 1
                if i < args.count { backend = args[i].lowercased() }
            case "--max-memory":
                i += 1
                if i < args.count {
                    // Parse "14GB" or "14"
                    let raw = args[i].uppercased().replacingOccurrences(of: "GB", with: "")
                    maxMemoryGB = Double(raw)
                }
            case "--max-context":
                i += 1
                if i < args.count, let n = Int(args[i]) { maxContext = n }
            case "--cluster":
                clusterMode = true
            case "--peers":
                i += 1
                if i < args.count {
                    // Parse comma-separated peers: "192.168.1.10:8080,192.168.1.11:8080"
                    peers = args[i].split(separator: ",").map(String.init)
                }
            case "--spillover":
                i += 1
                if i < args.count, let v = Double(args[i]) {
                    spilloverThreshold = max(0.0, min(1.0, v))
                }
            case "--draft-model":
                i += 1
                if i < args.count { draftModelPath = args[i] }
            case "--target-model":
                i += 1
                if i < args.count { targetModelPath = args[i] }
            case "--speculative-tokens":
                i += 1
                if i < args.count, let n = Int(args[i]) { speculativeTokens = max(1, min(16, n)) }
            case "--kv-quantize":
                i += 1
                if i < args.count {
                    kvQuantize = KVQuantizeMode(rawValue: args[i].lowercased()) ?? .off
                }
            case "--layer-skip":
                i += 1
                if i < args.count, let v = Double(args[i]) {
                    layerSkipThreshold = max(0.0, min(1.0, v))
                }
            case "--task":
                i += 1
                if i < args.count { layerSkipTask = args[i].lowercased() }
            case "--vllm-endpoint":
                i += 1
                if i < args.count { vllmEndpoint = args[i] }
            case "--genome-mode":
                genomeMode = true
            case "--genome-output-path":
                i += 1
                if i < args.count { genomeOutputPath = args[i] }
            default:
                if modelPath == nil && !args[i].hasPrefix("-") {
                    modelPath = args[i]
                }
            }
            i += 1
        }

        let resolvedPath = modelPath ?? ProcessInfo.processInfo.environment["HAYABUSA_MODEL"]

        // Speculative decoding mode uses --draft-model and --target-model instead
        let isSpeculativeMode = draftModelPath != nil && targetModelPath != nil
        let isVllmMode = backend == "vllm-mlx"

        guard isSpeculativeMode || isVllmMode || (resolvedPath != nil && !resolvedPath!.isEmpty) else {
            print("Usage: hayabusa <model-path> [--backend llama|mlx|vllm-mlx] [--slots N] [--ctx-per-slot N]")
            print("  --backend             Inference backend: llama (default), mlx, or vllm-mlx")
            print("  --slots               KV cache slot count (default: 4)")
            print("  --ctx-per-slot        Context size per slot (default: 4096, llama only)")
            print("  --max-memory          MLX memory limit in GB (e.g. 14GB, mlx only)")
            print("  --max-context         Max KV cache context per generation (mlx only)")
            print("  --cluster             Enable cluster mode (Bonjour LAN auto-discovery)")
            print("  --peers               Comma-separated peer addresses (e.g. 192.168.1.10:8080)")
            print("  --spillover           Uzu spillover threshold 0.0-1.0 (default: 0.8)")
            print("")
            print("  Speculative Decoding:")
            print("  --draft-model PATH    Small/fast draft model for speculative decoding")
            print("  --target-model PATH   Large/accurate target model for verification")
            print("  --speculative-tokens  Number of tokens to speculate (default: 4)")
            print("")
            print("  KV Cache Quantization:")
            print("  --kv-quantize int8    Quantize KV cache to int8 (~50% memory savings)")
            print("  --kv-quantize tq3     TurboQuant 3-bit KV cache (~78% memory savings)")
            print("  --kv-quantize tq4     TurboQuant 4-bit KV cache (~72% memory savings)")
            print("")
            print("  Layer Skipping (MLX only):")
            print("  --layer-skip 0.3      Skip layers with importance <= 30%")
            print("  --task soap           Task-specific importance profile (default: soap)")
            print("")
            print("  vllm-mlx Proxy Backend:")
            print("  --vllm-endpoint URL   vllm-mlx server address (default: http://localhost:8000)")
            print("")
            print("  AI Genome:")
            print("  --genome-mode              Collect per-layer genome metrics and exit")
            print("  --genome-output-path PATH  Output path for genome JSON (default: genome.json)")
            print("")
            print("  llama backend:  hayabusa models/Qwen3.5-9B-Q4_K_M.gguf --backend llama")
            print("  mlx backend:    hayabusa mlx-community/Qwen2.5-7B-Instruct-4bit --backend mlx")
            print("  vllm-mlx:       hayabusa --backend vllm-mlx --vllm-endpoint http://localhost:8000")
            print("  speculative:    hayabusa --draft-model small.gguf --target-model large.gguf")
            print("")
            print("  or set HAYABUSA_MODEL environment variable")
            Foundation.exit(1)
        }

        let port = Int(ProcessInfo.processInfo.environment["HAYABUSA_PORT"] ?? "8080") ?? 8080

        var engine: any InferenceEngine
        var speculativeDecoder: SpeculativeDecoder?

        if isSpeculativeMode {
            // Speculative decoding mode
            print("[Hayabusa] Mode: Speculative Decoding")
            print("[Hayabusa] Draft model: \(draftModelPath!)")
            print("[Hayabusa] Target model: \(targetModelPath!)")
            print("[Hayabusa] Speculative tokens: \(speculativeTokens)")

            let decoder = try SpeculativeDecoder(
                draftModelPath: draftModelPath!,
                targetModelPath: targetModelPath!,
                slotCount: slotCount,
                perSlotCtx: ctxPerSlot,
                speculativeTokens: speculativeTokens
            )
            speculativeDecoder = decoder
            engine = decoder
        } else {
            let resolvedPath = resolvedPath ?? ""
            print("[Hayabusa] Backend: \(backend)")
            if !resolvedPath.isEmpty {
                print("[Hayabusa] Loading model: \(resolvedPath)")
            }

            if kvQuantize != .off {
                print("[Hayabusa] KV cache quantization: \(kvQuantize.description)")
            }

            // Layer skipping (MLX only)
            var layerSkipConfig: LayerSkipConfig?
            if let threshold = layerSkipThreshold, backend == "mlx" {
                layerSkipConfig = try LayerSkipConfig(threshold: threshold, task: layerSkipTask)
            }

            switch backend {
            case "vllm-mlx":
                engine = try await VllmMLXBackend(
                    endpoint: vllmEndpoint ?? "http://localhost:8000"
                )
            case "mlx":
                engine = try await MLXEngine(
                    modelId: resolvedPath,
                    slotCount: slotCount,
                    maxMemoryGB: maxMemoryGB,
                    maxContext: maxContext,
                    layerSkipConfig: layerSkipConfig
                )
            default:
                engine = try LlamaEngine.withQuantization(
                    modelPath: resolvedPath,
                    slotCount: slotCount,
                    perSlotCtx: ctxPerSlot,
                    kvQuantize: kvQuantize
                )
                print("[Hayabusa] KV cache: \(slotCount) slots x \(ctxPerSlot) ctx = \(UInt32(slotCount) * ctxPerSlot) total")
            }
        }

        print("[Hayabusa] Model loaded (\(engine.modelDescription))")
        print("[Hayabusa] Slots: \(slotCount)")

        if genomeMode {
            guard let mlxEngine = engine as? MLXEngine else {
                print("[Genome] Error: genome mode requires --backend mlx")
                Foundation.exit(1)
            }
            let config = GenomeConfig(outputPath: genomeOutputPath ?? "genome.json")
            try await mlxEngine.collectGenome(config: config)
            print("[Hayabusa] Genome collection complete.")
            Foundation.exit(0)
        }

        // Cluster mode (--cluster for Bonjour, --peers for explicit peers)
        let bindAddress: String
        var clusterManager: ClusterManager?
        if clusterMode || !peers.isEmpty {
            bindAddress = "0.0.0.0"
            let cm = ClusterManager(
                httpPort: port,
                backend: backend,
                model: resolvedPath ?? targetModelPath ?? "",
                slots: slotCount,
                spilloverThreshold: spilloverThreshold
            )
            cm.start()
            // Register explicit peers
            for peer in peers {
                cm.addExplicitPeer(peer)
            }
            clusterManager = cm
            let clusterEngine = ClusterEngine(localEngine: engine, clusterManager: cm)
            engine = clusterEngine
            if peers.isEmpty {
                print("[Hayabusa] Cluster mode enabled (Bonjour: _hayabusa._tcp)")
            } else {
                print("[Hayabusa] Cluster mode enabled (peers: \(peers.joined(separator: ", ")))")
            }
            print("[Hayabusa] Uzu routing (spillover=\(spilloverThreshold))")
        } else {
            bindAddress = "127.0.0.1"
        }

        print("[Hayabusa] Starting server on http://\(bindAddress):\(port)")
        // Extract layerSkipConfig from MLXEngine if available
        let activeLayerSkip: LayerSkipConfig?
        if let mlxEngine = engine as? MLXEngine {
            activeLayerSkip = mlxEngine.layerSkipConfig
        } else {
            activeLayerSkip = nil
        }

        let server = HayabusaServer(
            engine: engine,
            port: port,
            bindAddress: bindAddress,
            clusterManager: clusterManager,
            speculativeDecoder: speculativeDecoder,
            kvQuantizeMode: kvQuantize,
            layerSkipConfig: activeLayerSkip
        )
        try await server.run()
    }
}
