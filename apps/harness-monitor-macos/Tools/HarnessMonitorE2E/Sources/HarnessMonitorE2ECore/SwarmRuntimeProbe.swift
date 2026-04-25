import Foundation

public struct SwarmRuntimeProbe {
    public struct CommandResult {
        public let exitStatus: Int32
        public let stdout: Data
        public let stderr: Data

        public init(exitStatus: Int32, stdout: Data, stderr: Data) {
            self.exitStatus = exitStatus
            self.stdout = stdout
            self.stderr = stderr
        }
    }

    public struct RuntimeStatus: Codable {
        public let available: Bool
        public let required: Bool
        public let reason: String
    }

    public struct Report: Codable {
        public let runtimes: [String: RuntimeStatus]
        public let requiredMissing: [String]

        enum CodingKeys: String, CodingKey {
            case runtimes
            case requiredMissing = "required_missing"
        }
    }

    public typealias CommandLocator = (String) -> String?
    public typealias CommandRunner = (String, [String], TimeInterval?) -> CommandResult

    public let environment: [String: String]
    public let homeDirectory: URL
    public let commandLocator: CommandLocator
    public let commandRunner: CommandRunner

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        commandLocator: CommandLocator? = nil,
        commandRunner: CommandRunner? = nil
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.commandLocator = commandLocator ?? Self.makeCommandLocator(environment: environment)
        self.commandRunner = commandRunner ?? Self.defaultCommandRunner
    }

    public func run() -> Report {
        var runtimes: [String: RuntimeStatus] = [:]
        var requiredMissing: [String] = []

        func record(_ name: String, required: Bool, available: Bool, reason: String) {
            runtimes[name] = RuntimeStatus(available: available, required: required, reason: reason)
            if required && !available {
                requiredMissing.append(name)
            }
        }

        probeVersionedBinary(
            name: "claude",
            required: true,
            authOK: claudeAuthAvailable(),
            authReason: "claude auth status is not logged in",
            record: record
        )
        probeVersionedBinary(
            name: "codex",
            required: true,
            authOK: fileExists(homeDirectory.appendingPathComponent(".codex/auth.json")),
            authReason: "missing ~/.codex/auth.json",
            record: record
        )
        probeVersionedBinary(
            name: "gemini",
            required: false,
            authOK: environment["GEMINI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 } != nil
                || fileExists(homeDirectory.appendingPathComponent(".config/gemini/credentials")),
            authReason: "missing GEMINI_API_KEY or ~/.config/gemini/credentials",
            record: record
        )

        if let ghPath = commandLocator("gh"),
           commandRunner(ghPath, ["copilot", "--help"], 3).exitStatus == 0 {
            record("copilot", required: false, available: true, reason: "available")
        } else {
            record("copilot", required: false, available: false, reason: "gh copilot unavailable")
        }

        probeVersionedBinary(name: "vibe", required: false, authOK: true, authReason: "available", record: record)
        probeVersionedBinary(name: "opencode", required: false, authOK: true, authReason: "available", record: record)

        return Report(runtimes: runtimes, requiredMissing: requiredMissing)
    }

    public static func encoded(_ report: Report) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    private func probeVersionedBinary(
        name: String,
        required: Bool,
        authOK: Bool,
        authReason: String,
        record: (_ name: String, _ required: Bool, _ available: Bool, _ reason: String) -> Void
    ) {
        guard let binaryPath = commandLocator(name) else {
            record(name, required, false, "binary '\(name)' not found")
            return
        }
        guard authOK else {
            record(name, required, false, authReason)
            return
        }
        let result = commandRunner(binaryPath, ["--version"], 3)
        if result.exitStatus == 0 {
            record(name, required, true, "available")
        } else {
            record(name, required, false, "'\(name) --version' failed or timed out")
        }
    }

    private func claudeAuthAvailable() -> Bool {
        if let apiKey = environment["ANTHROPIC_API_KEY"], apiKey.isEmpty == false {
            return true
        }
        if let token = environment["CLAUDE_CODE_OAUTH_TOKEN"], token.isEmpty == false {
            return true
        }

        if let claudePath = commandLocator("claude") {
            let result = commandRunner(claudePath, ["auth", "status"], 5)
            if result.exitStatus == 0,
               let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
               let loggedIn = json["loggedIn"] as? Bool {
                return loggedIn
            }
        }

        return fileExists(homeDirectory.appendingPathComponent(".config/claude-code/config.json"))
            || fileExists(homeDirectory.appendingPathComponent(".claude.json"))
    }

    private func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func makeCommandLocator(environment: [String: String]) -> CommandLocator {
        let path = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let searchDirectories = path.split(separator: ":").map(String.init)
        return { name in
            if name.contains("/") {
                return FileManager.default.isExecutableFile(atPath: name) ? name : nil
            }
            for directory in searchDirectories {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate.path
                }
            }
            return nil
        }
    }

    private static func defaultCommandRunner(
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return CommandResult(exitStatus: 127, stdout: Data(), stderr: Data(String(describing: error).utf8))
        }

        if let timeout {
            let deadline = Date.now.addingTimeInterval(timeout)
            while process.isRunning && Date.now < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                process.terminate()
                return CommandResult(exitStatus: 124, stdout: Data(), stderr: Data())
            }
        }

        process.waitUntilExit()
        return CommandResult(
            exitStatus: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }
}
