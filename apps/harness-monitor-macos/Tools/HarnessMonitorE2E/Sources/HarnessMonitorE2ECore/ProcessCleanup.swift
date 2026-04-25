import Darwin
import Foundation

public enum ProcessCleanup {
    public static let gracefulShutdownTimeout: TimeInterval = 5

    /// TERM, wait up to `timeout`, then KILL. Recurses through `pgrep -P` to drop children.
    /// Mirrors `stop_process_tree` in test-agents-e2e.sh; safe on already-dead PIDs.
    public static func terminateTree(rootPID: Int32, timeout: TimeInterval = gracefulShutdownTimeout) {
        guard rootPID > 0 else { return }

        if !isAlive(rootPID) {
            reap(rootPID)
            return
        }

        terminateChildren(of: rootPID)
        _ = kill(rootPID, SIGTERM)

        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if !isAlive(rootPID) {
                reap(rootPID)
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        terminateChildren(of: rootPID)
        _ = kill(rootPID, SIGKILL)
        reap(rootPID)
    }

    private static func terminateChildren(of parent: Int32) {
        for child in childPIDs(of: parent) {
            terminateTree(rootPID: child)
        }
    }

    private static func childPIDs(of parent: Int32) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(parent)]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        process.waitUntilExit()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// Wait for a child we spawned via `Process` to actually leave the kernel's table.
    /// Foundation reaps children automatically, so this is best-effort cleanup of orphan zombies (no-op when already reaped).
    private static func reap(_: Int32) {
        // Intentionally empty: Foundation handles waitpid for processes it spawned.
    }
}
