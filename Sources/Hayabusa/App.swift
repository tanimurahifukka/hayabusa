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
            default:
                if modelPath == nil && !args[i].hasPrefix("-") {
                    modelPath = args[i]
                }
            }
            i += 1
        }

        let resolvedPath = modelPath ?? ProcessInfo.processInfo.environment["HAYABUSA_MODEL"]

        guard let resolvedPath, !resolvedPath.isEmpty else {
            print("Usage: hayabusa <model-path> [--backend llama|mlx] [--slots N] [--ctx-per-slot N]")
            print("  --backend       Inference backend: llama (default) or mlx")
            print("  --slots         KV cache slot count (default: 4)")
            print("  --ctx-per-slot  Context size per slot (default: 4096, llama only)")
            print("  --max-memory    MLX memory limit in GB (e.g. 14GB, mlx only)")
            print("  --max-context   Max KV cache context per generation (mlx only)")
            print("  --cluster       Enable cluster mode (Bonjour LAN auto-discovery)")
            print("  --peers         Comma-separated peer addresses (e.g. 192.168.1.10:8080)")
            print("")
            print("  llama backend:  hayabusa models/Qwen3.5-9B-Q4_K_M.gguf --backend llama")
            print("  mlx backend:    hayabusa mlx-community/Qwen2.5-7B-Instruct-4bit --backend mlx")
            print("")
            print("  or set HAYABUSA_MODEL environment variable")
            Foundation.exit(1)
        }

        let port = Int(ProcessInfo.processInfo.environment["HAYABUSA_PORT"] ?? "8080") ?? 8080

        print("[Hayabusa] Backend: \(backend)")
        print("[Hayabusa] Loading model: \(resolvedPath)")

        var engine: any InferenceEngine
        switch backend {
        case "mlx":
            engine = try await MLXEngine(
                modelId: resolvedPath,
                slotCount: slotCount,
                maxMemoryGB: maxMemoryGB,
                maxContext: maxContext
            )
        default:
            engine = try LlamaEngine(modelPath: resolvedPath, slotCount: slotCount, perSlotCtx: ctxPerSlot)
            print("[Hayabusa] KV cache: \(slotCount) slots x \(ctxPerSlot) ctx = \(UInt32(slotCount) * ctxPerSlot) total")
        }

        print("[Hayabusa] Model loaded (\(engine.modelDescription))")
        print("[Hayabusa] Slots: \(slotCount)")

        // Cluster mode (--cluster for Bonjour, --peers for explicit peers)
        let bindAddress: String
        var clusterManager: ClusterManager?
        if clusterMode || !peers.isEmpty {
            bindAddress = "0.0.0.0"
            let cm = ClusterManager(
                httpPort: port,
                backend: backend,
                model: resolvedPath,
                slots: slotCount
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
        } else {
            bindAddress = "127.0.0.1"
        }

        print("[Hayabusa] Starting server on http://\(bindAddress):\(port)")
        let server = HayabusaServer(
            engine: engine,
            port: port,
            bindAddress: bindAddress,
            clusterManager: clusterManager
        )
        try await server.run()
    }
}
