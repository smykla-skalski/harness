import Foundation

/// Single-writer lock dir under `tmp/perf/harness-monitor-instruments/.audit-lock`. Mirrors
/// `acquire_audit_lock` in run-instruments-audit.sh - presence of the dir means another audit
/// is in progress.
public enum AuditLock {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public struct Info: Codable, Equatable {
        public var runID: String
        public var label: String
        public var startedAtUTC: String
        public var runDir: String
        public var pid: Int32

        enum CodingKeys: String, CodingKey {
            case runID = "run_id"
            case label
            case startedAtUTC = "started_at_utc"
            case runDir = "run_dir"
            case pid
        }
    }

    /// Acquires the lock by creating `lockDir`. Throws if the directory already exists with a
    /// live PID. If the previous holder is gone, replaces the lock.
    public static func acquire(at lockDir: URL, info: Info) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: lockDir.path) {
            if try !staleLock(lockDir) {
                let existing = try Data(contentsOf: lockDir.appendingPathComponent("info.json"))
                throw Failure(message:
                    "audit already in progress; lock at \(lockDir.path):\n"
                    + (String(data: existing, encoding: .utf8) ?? "<unparseable>"))
            }
            try fm.removeItem(at: lockDir)
        }
        try fm.createDirectory(at: lockDir, withIntermediateDirectories: true)
        try writeInfo(info, into: lockDir)
    }

    public static func release(at lockDir: URL) {
        try? FileManager.default.removeItem(at: lockDir)
    }

    private static func staleLock(_ lockDir: URL) throws -> Bool {
        let infoURL = lockDir.appendingPathComponent("info.json")
        guard FileManager.default.fileExists(atPath: infoURL.path) else { return true }
        let data = try Data(contentsOf: infoURL)
        guard let info = try? JSONDecoder().decode(Info.self, from: data) else { return true }
        return !pidIsLive(info.pid)
    }

    private static func pidIsLive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private static func writeInfo(_ info: Info, into lockDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(info)
        try data.write(to: lockDir.appendingPathComponent("info.json"), options: .atomic)
    }
}
