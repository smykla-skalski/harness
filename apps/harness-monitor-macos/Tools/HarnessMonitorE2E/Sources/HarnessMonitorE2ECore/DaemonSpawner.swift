import Foundation

public enum DaemonSpawner {
    public enum Failure: Error, CustomStringConvertible {
        case spawnFailed(underlying: Error)
        case readinessTimeout

        public var description: String {
            switch self {
            case .spawnFailed(let underlying): return "Failed to spawn harness daemon: \(underlying)"
            case .readinessTimeout: return "Timed out waiting for daemon readiness"
            }
        }
    }

    /// Spawn `harness daemon serve --sandboxed --host 127.0.0.1 --port 0`, redirect stdout+stderr to `logURL`, and wait for the daemon to answer `daemon status`.
    public static func spawn(client: HarnessClient, logURL: URL, readinessTimeout: TimeInterval = 30) throws -> Process {
        let process = Process()
        process.executableURL = client.binary
        process.arguments = ["daemon", "serve", "--sandboxed", "--host", "127.0.0.1", "--port", "0"]
        process.environment = client.mergedEnvironment()

        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: logURL)
        process.standardOutput = handle
        process.standardError = handle

        do {
            try process.run()
        } catch {
            throw Failure.spawnFailed(underlying: error)
        }

        if !client.waitForDaemonReady(timeout: readinessTimeout) {
            ProcessCleanup.terminateTree(rootPID: process.processIdentifier)
            throw Failure.readinessTimeout
        }
        return process
    }
}
