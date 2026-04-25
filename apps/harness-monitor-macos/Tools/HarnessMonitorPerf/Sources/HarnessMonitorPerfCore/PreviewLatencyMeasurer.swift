import Foundation

/// Scrapes `log show` output for SwiftUI preview-injection markers and aggregates per-session
/// JIT-link latency. Direct port of measure-preview-latency.sh.
public enum PreviewLatencyMeasurer {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public struct Session: Equatable {
        public var process: String
        public var pid: Int
        public var firstJIT: Date?
        public var register: Date?
        public var entrypoint: Date?
    }

    public struct Report: Equatable {
        public var totalSessions: Int
        public var latestProcess: String
        public var latestPID: Int
        public var latestTotalSeconds: Double
        public var latestRegisterSeconds: Double?
        public var averageSeconds: Double
        public var medianSeconds: Double
        public var bestSeconds: Double
        public var worstSeconds: Double
    }

    public static let predicate = """
        eventMessage CONTAINS[c] "__previews_injection_perform_first_jit_link" \
        OR eventMessage CONTAINS[c] "__previews_injection_register_swift_extension_entry_section" \
        OR eventMessage CONTAINS[c] "__previews_injection_run_user_entrypoint"
        """

    /// Captures `log show --last <window> --style compact --predicate <pred>` and parses the
    /// output. Use `parse(_:)` directly when you already have the dump.
    public static func measure(window: String) throws -> Report {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let result = try ProcessRunner.runChecked(
            "/usr/bin/log",
            arguments: [
                "show",
                "--last", window,
                "--style", "compact",
                "--predicate", predicate,
            ]
        )
        return try parse(result.stdoutString, dateFormatter: formatter)
    }

    static let lineRegex: NSRegularExpression = {
        let pattern = #"^(?<timestamp>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})\s+\S+\s+(?<process>.+?)\[(?<pid>\d+):[^\]]+\].*(?<phase>__previews_injection_[^ ]+)"#
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: pattern)
    }()

    /// Pure parser entry point used by tests. Mirrors the python state machine: a
    /// __previews_injection_run_user_entrypoint line, paired with a prior
    /// __previews_injection_perform_first_jit_link, completes a session and resets state.
    public static func parse(_ logText: String, dateFormatter: DateFormatter) throws -> Report {
        var sessions: [SessionKey: Session] = [:]
        var completed: [Session] = []

        for rawLine in logText.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = lineRegex.firstMatch(in: line, options: [], range: range) else { continue }

            guard
                let tsRange = matchedRange(match: match, name: "timestamp", string: nsLine),
                let processRange = matchedRange(match: match, name: "process", string: nsLine),
                let pidRange = matchedRange(match: match, name: "pid", string: nsLine),
                let phaseRange = matchedRange(match: match, name: "phase", string: nsLine),
                let timestamp = dateFormatter.date(from: tsRange),
                let pid = Int(pidRange)
            else { continue }
            let process = processRange.trimmingCharacters(in: .whitespacesAndNewlines)
            let phase = phaseRange
            let key = SessionKey(process: process, pid: pid)
            var session = sessions[key] ?? Session(process: process, pid: pid)

            switch phase {
            case "__previews_injection_perform_first_jit_link":
                session.firstJIT = timestamp
                session.register = nil
                session.entrypoint = nil
            case "__previews_injection_register_swift_extension_entry_section":
                session.register = timestamp
            case "__previews_injection_run_user_entrypoint":
                session.entrypoint = timestamp
                if session.firstJIT != nil {
                    completed.append(session)
                    session = Session(process: process, pid: pid)
                }
            default:
                break
            }
            sessions[key] = session
        }

        guard !completed.isEmpty else {
            throw Failure(message: "No completed preview JIT sessions found in the requested window.")
        }

        let durations = completed.compactMap { session -> Double? in
            guard let first = session.firstJIT, let entry = session.entrypoint else { return nil }
            return entry.timeIntervalSince(first)
        }
        guard let latest = completed.last,
              let latestFirst = latest.firstJIT,
              let latestEntry = latest.entrypoint
        else {
            throw Failure(message: "completed session missing timestamps")
        }

        let latestTotal = latestEntry.timeIntervalSince(latestFirst)
        let latestRegister = latest.register.map { $0.timeIntervalSince(latestFirst) }
        return Report(
            totalSessions: durations.count,
            latestProcess: latest.process,
            latestPID: latest.pid,
            latestTotalSeconds: latestTotal,
            latestRegisterSeconds: latestRegister,
            averageSeconds: durations.reduce(0, +) / Double(durations.count),
            medianSeconds: median(durations),
            bestSeconds: durations.min() ?? 0,
            worstSeconds: durations.max() ?? 0
        )
    }

    public static func render(_ report: Report) -> String {
        var lines: [String] = []
        lines.append("Preview JIT sessions: \(report.totalSessions)")
        lines.append("Latest host: \(report.latestProcess) (pid \(report.latestPID))")
        lines.append(String(format: "Latest total: %.3fs", report.latestTotalSeconds))
        if let register = report.latestRegisterSeconds {
            lines.append(String(format: "Latest first-link to register: %.3fs", register))
        }
        lines.append(String(format: "Average total: %.3fs", report.averageSeconds))
        lines.append(String(format: "Median total: %.3fs", report.medianSeconds))
        lines.append(String(format: "Best total: %.3fs", report.bestSeconds))
        lines.append(String(format: "Worst total: %.3fs", report.worstSeconds))
        return lines.joined(separator: "\n")
    }

    private static func matchedRange(
        match: NSTextCheckingResult, name: String, string: NSString
    ) -> String? {
        let range = match.range(withName: name)
        guard range.location != NSNotFound else { return nil }
        return string.substring(with: range)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let count = sorted.count
        if count % 2 == 1 { return sorted[count / 2] }
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
    }

    private struct SessionKey: Hashable {
        var process: String
        var pid: Int
    }
}
