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

        let engine: any InferenceEngine
        switch backend {
        case "mlx":
            engine = try await MLXEngine(modelId: resolvedPath, slotCount: slotCount)
        default:
            engine = try LlamaEngine(modelPath: resolvedPath, slotCount: slotCount, perSlotCtx: ctxPerSlot)
            print("[Hayabusa] KV cache: \(slotCount) slots x \(ctxPerSlot) ctx = \(UInt32(slotCount) * ctxPerSlot) total")
        }

        print("[Hayabusa] Model loaded (\(engine.modelDescription))")
        print("[Hayabusa] Slots: \(slotCount)")
        print("[Hayabusa] Starting server on http://127.0.0.1:\(port)")
        let server = HayabusaServer(engine: engine, port: port)
        try await server.run()
    }
}
