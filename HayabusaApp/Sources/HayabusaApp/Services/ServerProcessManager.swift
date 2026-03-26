import Foundation

@Observable
final class ServerProcessManager {
    private(set) var state: ServerState = .stopped
    private(set) var logLines: [String] = []
    private var process: Process?
    private let maxLogLines = 10_000
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    var lastError: String?

    func start(settings: AppSettings) {
        guard state == .stopped || state == .error else { return }

        state = .starting
        logLines.removeAll()
        lastError = nil

        // Kill any existing process on the target port (off main thread)
        let port = settings.port
        DispatchQueue.global(qos: .userInitiated).async {
            Self.killProcessOnPort(port)
            DispatchQueue.main.async { [weak self] in
                self?.launchProcess(settings: settings)
            }
        }
    }

    private func launchProcess(settings: AppSettings) {
        guard state == .starting else { return }

        let config = HayabusaConfiguration(settings: settings)
        let binaryPath = config.resolvedBinaryPath()

        // Validate binary exists
        guard !binaryPath.isEmpty, FileManager.default.fileExists(atPath: binaryPath) else {
            state = .error
            if binaryPath.isEmpty {
                lastError = "Hayabusa server not found. Build it first or set path in Settings."
                appendLog("[Error] Hayabusa server binary not found")
                appendLog("")
                appendLog("To build the server:")
                appendLog("  1. cd ~/Desktop/hayabusa")
                appendLog("  2. swift build -c release")
                appendLog("")
                appendLog("Or set the path manually in Settings → Hayabusa Binary")
            } else {
                lastError = "Binary not found: \(binaryPath)"
                appendLog("[Error] Binary not found: \(binaryPath)")
                appendLog("[Hint] Set the correct path in Settings → Hayabusa Binary")
            }
            return
        }

        // Validate binary is executable
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            state = .error
            lastError = "Binary is not executable: \(binaryPath)"
            appendLog("[Error] Binary is not executable: \(binaryPath)")
            appendLog("[Hint] Run: chmod +x \(binaryPath)")
            return
        }

        // Validate model path is set
        if settings.modelPath.isEmpty {
            state = .error
            lastError = "No model path configured"
            appendLog("[Error] No model path set")
            appendLog("[Hint] Set a model path in Settings or the Models tab")
            return
        }

        // Validate model exists
        if settings.backend == "llama" {
            // GGUF file must exist on disk
            let expandedPath = NSString(string: settings.modelPath).expandingTildeInPath
            if !FileManager.default.fileExists(atPath: expandedPath) {
                state = .error
                lastError = "Model file not found: \(settings.modelPath)"
                appendLog("[Error] Model file not found: \(settings.modelPath)")
                appendLog("[Hint] For llama backend, provide a path to a .gguf file")
                appendLog("[Hint] Example: ~/models/Qwen3.5-9B-Q4_K_M.gguf")
                return
            }
        } else if settings.backend == "mlx" {
            // MLX: must be a HuggingFace model ID (containing /) or a local directory
            let expandedPath = NSString(string: settings.modelPath).expandingTildeInPath
            let isLocalDir = FileManager.default.fileExists(atPath: expandedPath)
            let isHFModelId = settings.modelPath.contains("/") && !settings.modelPath.hasPrefix("/") && !settings.modelPath.hasPrefix("~")
            if !isLocalDir && !isHFModelId {
                state = .error
                lastError = "Invalid MLX model: \(settings.modelPath)"
                appendLog("[Error] Invalid MLX model path: \(settings.modelPath)")
                appendLog("[Hint] For MLX backend, use a HuggingFace model ID or local directory")
                appendLog("[Hint] Example: mlx-community/Qwen3.5-9B-MLX-4bit")
                return
            }
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = config.buildArguments()
        proc.environment = config.buildEnvironment()
        // Set working directory to binary's parent so relative paths resolve
        proc.currentDirectoryURL = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Read stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.appendLog(line)
                if line.contains("Starting server on") || line.contains("Server started") {
                    self?.state = .running
                }
            }
        }

        // Read stderr
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.appendLog(line)
            }
        }

        proc.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.stdoutPipe?.fileHandleForReading.readabilityHandler = nil
                self?.stderrPipe?.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    self?.state = .stopped
                } else {
                    self?.state = .error
                    self?.appendLog("[Process exited with code \(process.terminationStatus)]")
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            appendLog("[Starting Hayabusa: \(binaryPath)]")
            appendLog("[Args: \(config.buildArguments().joined(separator: " "))]")
        } catch {
            state = .error
            appendLog("[Failed to start: \(error.localizedDescription)]")
        }
    }

    func stop() {
        guard let proc = process, proc.isRunning else {
            state = .stopped
            return
        }

        appendLog("[Stopping server (SIGTERM)...]")
        proc.terminate() // SIGTERM

        // Force kill after 5 seconds if still running
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let proc = self?.process, proc.isRunning else { return }
            proc.interrupt() // SIGINT as fallback
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                guard let proc = self?.process, proc.isRunning else { return }
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    private func appendLog(_ text: String) {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        logLines.append(contentsOf: lines)
        if logLines.count > maxLogLines {
            logLines.removeFirst(logLines.count - maxLogLines)
        }
    }

    /// Kill any process listening on the given port (cleanup stale servers).
    private static func killProcessOnPort(_ port: Int) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-ti", ":\(port)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            for pidStr in output.components(separatedBy: .newlines) {
                if let pid = Int32(pidStr.trimmingCharacters(in: .whitespaces)), pid > 0 {
                    kill(pid, SIGTERM)
                }
            }
            if !output.isEmpty {
                Thread.sleep(forTimeInterval: 0.5)
            }
        } catch {}
    }
}
