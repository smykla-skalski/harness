import Foundation

/// Minimal client that runs `harness <args>` with the same env contract `run_harness` enforces in test-agents-e2e.sh.
public struct HarnessClient {
    public let binary: URL
    public let dataHome: URL

    public init(binary: URL, dataHome: URL) {
        self.binary = binary
        self.dataHome = dataHome
    }

    public struct Output {
        public let exitStatus: Int32
        public let stdout: Data
        public let stderr: Data
    }

    public func run(_ arguments: [String]) -> Output {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = mergedEnvironment()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return Output(exitStatus: 127, stdout: Data(), stderr: Data("failed to launch \(binary.path): \(error)".utf8))
        }
        process.waitUntilExit()
        return Output(
            exitStatus: process.terminationStatus,
            stdout: stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr: stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }

    public func mergedEnvironment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["XDG_DATA_HOME"] = dataHome.path
        env["HARNESS_DAEMON_DATA_HOME"] = dataHome.path
        for (key, value) in extra { env[key] = value }
        return env
    }

    public func waitForDaemonReady(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if run(["daemon", "status"]).exitStatus == 0 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    public func bridgeReady() -> Bool {
        let result = run(["bridge", "status"])
        guard result.exitStatus == 0 else { return false }
        return BridgeReadiness.isReady(fromJSON: result.stdout)
    }

    public func startSession(
        sessionID: String, title: String, context: String, projectDir: URL
    ) -> Output {
        run([
            "session", "start",
            "--context", context,
            "--title", title,
            "--project-dir", projectDir.path,
            "--session-id", sessionID,
        ])
    }

    public func sessionWorkspace(sessionID: String, projectDir: URL) -> String? {
        let result = run([
            "session", "status", sessionID,
            "--json",
            "--project-dir", projectDir.path,
        ])
        guard result.exitStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
              let path = json["worktree_path"] as? String, !path.isEmpty
        else { return nil }
        return path
    }
}
