import Foundation

struct HayabusaConfiguration {
    let settings: AppSettings

    func buildArguments() -> [String] {
        var args: [String] = []

        // Model path (first positional argument)
        if !settings.modelPath.isEmpty {
            args.append(settings.modelPath)
        }

        // Backend
        args.append("--backend")
        args.append(settings.backend)

        // Slots
        args.append("--slots")
        args.append(String(settings.slotCount))

        // Backend-specific
        if settings.backend == "llama" {
            args.append("--ctx-per-slot")
            args.append(String(settings.ctxPerSlot))
        } else if settings.backend == "mlx" {
            args.append("--max-memory")
            args.append("\(Int(settings.maxMemoryGB))GB")
            args.append("--max-context")
            args.append(String(settings.maxContext))
        }

        // Cluster
        if settings.clusterEnabled {
            args.append("--cluster")
        }

        return args
    }

    func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HAYABUSA_PORT"] = String(settings.port)
        // GUI apps may have a limited PATH — ensure common tool locations are included
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin"
        let combined = (extraPaths + currentPath.components(separatedBy: ":"))
            .reduce(into: [String]()) { result, p in
                if !result.contains(p) { result.append(p) }
            }
        env["PATH"] = combined.joined(separator: ":")
        return env
    }

    /// Auto-detect Hayabusa binary by searching common locations.
    func resolvedBinaryPath() -> String {
        // 1. User explicitly set a path → use it
        if !settings.hayabusaBinaryPath.isEmpty {
            return settings.hayabusaBinaryPath
        }

        let fm = FileManager.default

        // 2. Walk up from the GUI binary to find the project root
        //    e.g. /path/to/hayabusa/HayabusaApp/.build/debug/HayabusaApp
        //         → /path/to/hayabusa/.build/release/Hayabusa
        var dir = (Bundle.main.executablePath ?? Bundle.main.bundlePath) as NSString
        for _ in 0..<8 {
            dir = dir.deletingLastPathComponent as NSString
            let candidate = dir.appendingPathComponent(".build/release/Hayabusa")
            if fm.fileExists(atPath: candidate) { return candidate }
            let candidateDbg = dir.appendingPathComponent(".build/debug/Hayabusa")
            if fm.fileExists(atPath: candidateDbg) { return candidateDbg }
        }

        // 3. Common absolute paths (including platform-specific build dirs)
        let home = NSHomeDirectory()
        let searchDirs = [
            "\(home)/Desktop/hayabusa",
            "\(home)/Desktop/Lang/hayabusa",
            "\(home)/hayabusa",
            "\(home)/Projects/hayabusa",
            "\(home)/Developer/hayabusa",
        ]
        var candidates: [String] = []
        for base in searchDirs {
            // SwiftPM platform-specific path (arm64-apple-macosx)
            candidates.append("\(base)/.build/arm64-apple-macosx/release/Hayabusa")
            candidates.append("\(base)/.build/release/Hayabusa")
            candidates.append("\(base)/.build/arm64-apple-macosx/debug/Hayabusa")
            candidates.append("\(base)/.build/debug/Hayabusa")
        }
        candidates.append(contentsOf: [
            "/usr/local/bin/hayabusa",
            "/opt/homebrew/bin/hayabusa",
        ])
        for path in candidates {
            if fm.fileExists(atPath: path) { return path }
        }

        // 4. Check PATH via `which`
        if let whichResult = Self.which("Hayabusa"), fm.fileExists(atPath: whichResult) {
            return whichResult
        }
        if let whichResult = Self.which("hayabusa"), fm.fileExists(atPath: whichResult) {
            return whichResult
        }

        // 5. Not found — return empty so the error message is clear
        return ""
    }

    private static func which(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return result?.isEmpty == false ? result : nil
        } catch {
            return nil
        }
    }
}
