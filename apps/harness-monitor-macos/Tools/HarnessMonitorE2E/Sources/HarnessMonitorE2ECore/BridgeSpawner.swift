import Foundation

public enum BridgeSpawner {
    public enum Failure: Error, CustomStringConvertible {
        case spawnFailed(underlying: Error)
        case readinessTimeout
        case exhaustedAttempts(attempts: Int)

        public var description: String {
            switch self {
            case .spawnFailed(let underlying): return "Failed to spawn harness bridge: \(underlying)"
            case .readinessTimeout: return "Timed out waiting for bridge readiness"
            case .exhaustedAttempts(let attempts): return "Bridge failed to start after \(attempts) attempts"
            }
        }
    }

    public struct Result {
        public let process: Process
        public let port: UInt16
    }

    public static let portConflictMarker = "Address already in use"

    /// Mirror of the shell `start_bridge` retry loop:
    /// when no port override is set, allocate a fresh port up to `maxAttempts` times when the bridge dies with EADDRINUSE.
    public static func spawn(
        client: HarnessClient,
        codexBinary: URL,
        logURL: URL,
        portOverride: UInt16? = nil,
        maxAttemptsWithoutOverride: Int = 5,
        readinessTimeout: TimeInterval = 60
    ) throws -> Result {
        let attempts = portOverride == nil ? maxAttemptsWithoutOverride : 1
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        for attempt in 1...attempts {
            let port = try portOverride ?? PortAllocator.allocateLocalTCPPort()
            try appendHeader(logURL: logURL, attempt: attempt, port: port)
            let process = try launch(client: client, codexBinary: codexBinary, port: port, logURL: logURL)

            if waitForBridgeReady(client: client, process: process, timeout: readinessTimeout) {
                return Result(process: process, port: port)
            }

            ProcessCleanup.terminateTree(rootPID: process.processIdentifier)

            if portOverride == nil, didFailWithPortConflict(logURL: logURL) {
                continue
            }
            throw Failure.readinessTimeout
        }
        throw Failure.exhaustedAttempts(attempts: attempts)
    }

    private static func launch(client: HarnessClient, codexBinary: URL, port: UInt16, logURL: URL) throws -> Process {
        let process = Process()
        process.executableURL = client.binary
        process.arguments = [
            "bridge", "start",
            "--capability", "codex",
            "--capability", "agent-tui",
            "--codex-port", String(port),
            "--codex-path", codexBinary.path,
        ]
        process.environment = client.mergedEnvironment()

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        process.standardOutput = handle
        process.standardError = handle

        do {
            try process.run()
        } catch {
            throw Failure.spawnFailed(underlying: error)
        }
        return process
    }

    private static func waitForBridgeReady(client: HarnessClient, process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if client.bridgeReady() { return true }
            if !process.isRunning { return false }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    private static func didFailWithPortConflict(logURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: logURL),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(portConflictMarker)
    }

    private static func appendHeader(logURL: URL, attempt: Int, port: UInt16) throws {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        let header = "=== bridge attempt \(attempt) codex_port=\(port) ===\n"
        try handle.write(contentsOf: Data(header.utf8))
        try handle.close()
    }
}
