// ServerCommand.swift — サーバーデーモン管理（start/stop/status + launchd plist生成）

import Foundation

struct ServerCommand {
    static let pidFile = NSHomeDirectory() + "/.hayabusa/hayabusa.pid"
    static let logFile = NSHomeDirectory() + "/.hayabusa/hayabusa.log"
    static let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.kajiba.hayabusa.plist"

    static func run(args: [String]) async {
        guard let subcommand = args.first else {
            printUsage()
            return
        }

        switch subcommand {
        case "start":
            await start(args: Array(args.dropFirst()))
        case "stop":
            stop()
        case "status":
            await status()
        case "install":
            install(args: Array(args.dropFirst()))
        case "uninstall":
            uninstall()
        default:
            fputs("Unknown server command: \(subcommand)\n", stderr)
            printUsage()
        }
    }

    // MARK: - Start

    static func start(args: [String]) async {
        // ディレクトリ作成
        let dir = NSHomeDirectory() + "/.hayabusa"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // 既に起動中か確認
        if let pid = readPID(), isProcessRunning(pid) {
            print("Hayabusaサーバーは既に起動中です (PID: \(pid))")
            return
        }

        // Hayabusaバイナリを探す
        guard let binary = findBinary() else {
            fputs("Error: Hayabusaバイナリが見つかりません。swift build -c release を実行してください。\n", stderr)
            return
        }

        // 引数を構築（指定なしならconfig.jsonからデフォルトモデルを読む）
        let launchArgs: [String]
        if args.isEmpty {
            if let config = loadConfig() {
                let model = config["default_model"] as? String ?? ""
                let backend = config["default_backend"] as? String ?? "llama"
                let kv = config["kv_quantize"] as? String ?? "off"
                let projectDir = config["project_dir"] as? String ?? ""

                var resolved = model
                if !FileManager.default.fileExists(atPath: resolved) && !projectDir.isEmpty {
                    resolved = projectDir + "/" + model
                }

                guard FileManager.default.fileExists(atPath: resolved) else {
                    fputs("Error: モデルが見つかりません: \(resolved)\n", stderr)
                    fputs("~/.hayabusa/config.json の default_model を確認してください。\n", stderr)
                    return
                }

                var a = [resolved, "--backend", backend]
                if kv != "off" { a += ["--kv-quantize", kv] }
                launchArgs = a
                print("Config: \(resolved) (backend=\(backend), kv=\(kv))")
            } else {
                fputs("Error: モデルパスを指定するか、~/.hayabusa/config.json を作成してください。\n", stderr)
                fputs("  hayabusa server start models/model.gguf\n", stderr)
                fputs("  または: bash scripts/setup.sh\n", stderr)
                return
            }
        } else {
            launchArgs = args
        }

        // バックグラウンドでプロセスを起動
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = launchArgs
        process.standardOutput = FileHandle(forWritingAtPath: logFile) ?? FileHandle.nullDevice
        process.standardError = FileHandle(forWritingAtPath: logFile) ?? FileHandle.nullDevice

        // ログファイル作成
        FileManager.default.createFile(atPath: logFile, contents: nil)

        do {
            try process.run()
            let pid = process.processIdentifier
            try "\(pid)".write(toFile: pidFile, atomically: true, encoding: .utf8)
            print("Hayabusaサーバーを起動しました (PID: \(pid))")
            print("ログ: \(logFile)")

            // ヘルスチェック待ち
            let client = HayabusaClient()
            for i in 1...30 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if let ok = try? await client.health(), ok {
                    print("サーバー準備完了 (\(i)秒)")
                    return
                }
            }
            fputs("Warning: サーバーは起動しましたが、ヘルスチェックに応答しません。\n", stderr)
            fputs("ログを確認してください: tail -f \(logFile)\n", stderr)
        } catch {
            fputs("Error: サーバー起動に失敗しました: \(error)\n", stderr)
        }
    }

    // MARK: - Stop

    static func stop() {
        guard let pid = readPID() else {
            print("Hayabusaサーバーは起動していません。")
            return
        }

        if isProcessRunning(pid) {
            kill(pid, SIGTERM)
            print("Hayabusaサーバーを停止しました (PID: \(pid))")
        } else {
            print("サーバープロセスは既に終了しています。")
        }

        try? FileManager.default.removeItem(atPath: pidFile)
    }

    // MARK: - Status

    static func status() async {
        if let pid = readPID(), isProcessRunning(pid) {
            print("Status: RUNNING (PID: \(pid))")

            let client = HayabusaClient()
            if let ok = try? await client.health(), ok {
                print("Health: OK")
                if let slots = try? await client.slots() {
                    print("Slots: \(slots)")
                }
            } else {
                print("Health: NOT RESPONDING")
            }
        } else {
            print("Status: STOPPED")
        }
    }

    // MARK: - launchd Install

    static func install(args: [String]) {
        guard let binary = findBinary() else {
            fputs("Error: Hayabusaバイナリが見つかりません。\n", stderr)
            return
        }

        let serverArgs = args.isEmpty
            ? ["models/Qwen3.5-9B-Q4_K_M.gguf"]
            : args

        let programArgs = [binary] + serverArgs

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.kajiba.hayabusa</string>
            <key>ProgramArguments</key>
            <array>
        \(programArgs.map { "        <string>\($0)</string>" }.joined(separator: "\n"))
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>StandardOutPath</key>
            <string>\(logFile)</string>
            <key>StandardErrorPath</key>
            <string>\(logFile)</string>
            <key>WorkingDirectory</key>
            <string>\(FileManager.default.currentDirectoryPath)</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>HAYABUSA_PORT</key>
                <string>8080</string>
            </dict>
        </dict>
        </plist>
        """

        do {
            // LaunchAgentsディレクトリ作成
            let launchAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
            try FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

            try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
            print("launchd plistを生成しました: \(plistPath)")
            print("")
            print("自動起動を有効にするには:")
            print("  launchctl load \(plistPath)")
            print("")
            print("無効にするには:")
            print("  launchctl unload \(plistPath)")
        } catch {
            fputs("Error: plist生成に失敗しました: \(error)\n", stderr)
        }
    }

    // MARK: - launchd Uninstall

    static func uninstall() {
        // アンロード
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unload", plistPath]
        try? process.run()
        process.waitUntilExit()

        // plist削除
        try? FileManager.default.removeItem(atPath: plistPath)
        print("launchd plistを削除しました。")
    }

    // MARK: - Helpers

    static func findBinary() -> String? {
        let candidates = [
            FileManager.default.currentDirectoryPath + "/.build/release/Hayabusa",
            FileManager.default.currentDirectoryPath + "/.build/debug/Hayabusa",
            "/usr/local/bin/hayabusa",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func readPID() -> Int32? {
        guard let str = try? String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(str) else { return nil }
        return pid
    }

    static func isProcessRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    static func loadConfig() -> [String: Any]? {
        let configPath = NSHomeDirectory() + "/.hayabusa/config.json"
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    static func printUsage() {
        print("""
        Usage: hayabusa server <command> [options]

        Commands:
          start <model> [args]   バックグラウンドでサーバー起動
          stop                   サーバー停止
          status                 起動状態確認
          install [model] [args] launchd plistを生成（Mac起動時に自動起動）
          uninstall              launchd plistを削除
        """)
    }
}
