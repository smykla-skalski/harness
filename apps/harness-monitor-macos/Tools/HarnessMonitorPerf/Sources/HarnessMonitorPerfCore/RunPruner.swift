import Foundation

/// Discards intermediate audit artifacts and enforces the retained run size budget. Mirrors
/// prune_run_artifacts / retain_run_file / prune_unretained_run_files /
/// assert_retained_run_size_budget in run-instruments-audit.sh.
public enum RunPruner {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static let retainedRunSizeBudgetKiB = 10_240

    public static func retain(relativePath: String, keepTraces: Bool) -> Bool {
        switch relativePath {
        case "manifest.json", "summary.json", "summary.csv",
             "captures.tsv", "comparison.json", "comparison.md":
            return true
        default:
            break
        }
        if relativePath.hasPrefix("logs/") && relativePath.hasSuffix(".log") {
            return true
        }
        if relativePath.hasPrefix("metrics/") {
            if relativePath.hasSuffix("/swiftui.json") { return true }
            if relativePath.hasSuffix("/allocations.json") { return true }
            if relativePath.hasSuffix("/top-offenders.json") { return true }
        }
        if relativePath.hasPrefix("comparison-") {
            if relativePath.hasSuffix("/comparison.json") { return true }
            if relativePath.hasSuffix("/comparison.md") { return true }
        }
        if relativePath.hasPrefix("traces/") { return keepTraces }
        return false
    }

    public static func prune(runDir: URL, keepTraces: Bool) throws {
        let fm = FileManager.default
        for relative in ["exports", "launch-host", "app-data", "xctrace-tmp"] {
            let url = runDir.appendingPathComponent(relative)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }

        let tracesRoot = runDir.appendingPathComponent("traces", isDirectory: true)
        if !keepTraces, fm.fileExists(atPath: tracesRoot.path) {
            try? fm.removeItem(at: tracesRoot)
        }

        try pruneUnretainedFiles(runDir: runDir, keepTraces: keepTraces)
        try assertRetainedSize(runDir: runDir, keepTraces: keepTraces)
        try removeEmptyDirectories(runDir: runDir)
    }

    private static func pruneUnretainedFiles(runDir: URL, keepTraces: Bool) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: runDir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let basePath = runDir.standardizedFileURL.path
        for case let url as URL in enumerator {
            let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(basePath + "/") else { continue }
            let relative = String(path.dropFirst(basePath.count + 1))
            if !retain(relativePath: relative, keepTraces: keepTraces) {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static func assertRetainedSize(runDir: URL, keepTraces: Bool) throws {
        if keepTraces { return }
        let result = try ProcessRunner.run("/usr/bin/du", arguments: ["-sk", runDir.path])
        let firstField = result.stdoutString.split(separator: "\n").first.flatMap {
            $0.split(separator: "\t").first.map(String.init)
        } ?? ""
        let kib = Int(firstField.trimmingCharacters(in: .whitespaces)) ?? 0
        if kib > retainedRunSizeBudgetKiB {
            throw Failure(
                message: "Retained audit run exceeded the \(retainedRunSizeBudgetKiB) KiB size budget (\(kib) KiB): \(runDir.path)"
            )
        }
    }

    private static func removeEmptyDirectories(runDir: URL) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: runDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues?.isDirectory == true { directories.append(url) }
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            let entries = try? fm.contentsOfDirectory(atPath: directory.path)
            if entries?.isEmpty == true {
                try? fm.removeItem(at: directory)
            }
        }
    }
}
