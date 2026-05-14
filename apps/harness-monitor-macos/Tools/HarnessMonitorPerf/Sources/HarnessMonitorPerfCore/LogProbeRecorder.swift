import Darwin
import Foundation

/// Launches audit scenarios without Instruments and captures unified logs for quick
/// runtime-warning checks.
public enum LogProbeRecorder {
    public static let templateName = "LogOnly"
    public static let templateSlug = "log-only"

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public struct ScenarioInputs {
        public var scenario: String
        public var previewScenario: String
        public var durationSeconds: Int
        public var hostAppPath: URL
        public var hostBinaryPath: URL
        public var launchArguments: [String]
        public var environment: [String: String]
        public var logURL: URL
        public var stdoutURL: URL
        public var stderrURL: URL
        public var daemonDataHome: URL
        public var daemonDataHomeProbe: URL?
        public var runDir: URL
        public var appTraceRelpath: String?

        public init(
            scenario: String, previewScenario: String, durationSeconds: Int,
            hostAppPath: URL, hostBinaryPath: URL, launchArguments: [String],
            environment: [String: String], logURL: URL, stdoutURL: URL, stderrURL: URL,
            daemonDataHome: URL, daemonDataHomeProbe: URL? = nil, runDir: URL,
            appTraceRelpath: String? = nil
        ) {
            self.scenario = scenario
            self.previewScenario = previewScenario
            self.durationSeconds = durationSeconds
            self.hostAppPath = hostAppPath
            self.hostBinaryPath = hostBinaryPath
            self.launchArguments = launchArguments
            self.environment = environment
            self.logURL = logURL
            self.stdoutURL = stdoutURL
            self.stderrURL = stderrURL
            self.daemonDataHome = daemonDataHome
            self.daemonDataHomeProbe = daemonDataHomeProbe
            self.runDir = runDir
            self.appTraceRelpath = appTraceRelpath
        }
    }

    public struct WarningSummary: Codable, Equatable {
        public var swiftUIFrameUpdateWarnings: Int
        public var tableViewReentrantWarnings: Int
        public var attributeGraphCycleWarnings: Int
        public var databaseOpenWarnings: Int
        public var appDataPromptHints: Int
        public var duplicateRuntimeClassWarnings: Int
        public var stateMutationWarnings: Int
        public var mainThreadCheckerWarnings: Int
        public var sandboxDenials: Int
        public var sqliteWarnings: Int

        enum CodingKeys: String, CodingKey {
            case swiftUIFrameUpdateWarnings = "swiftui_frame_update_warnings"
            case tableViewReentrantWarnings = "table_view_reentrant_warnings"
            case attributeGraphCycleWarnings = "attribute_graph_cycle_warnings"
            case databaseOpenWarnings = "database_open_warnings"
            case appDataPromptHints = "app_data_prompt_hints"
            case duplicateRuntimeClassWarnings = "duplicate_runtime_class_warnings"
            case stateMutationWarnings = "state_mutation_warnings"
            case mainThreadCheckerWarnings = "main_thread_checker_warnings"
            case sandboxDenials = "sandbox_denials"
            case sqliteWarnings = "sqlite_warnings"
        }
    }

    public struct Report: Codable, Equatable {
        public var scenario: String
        public var durationSeconds: Int
        public var processID: Int32
        public var exitStatus: Int32
        public var endReason: String
        public var launchedProcessPath: String
        public var logRelpath: String
        public var stdoutRelpath: String
        public var stderrRelpath: String
        public var appTraceRelpath: String?
        public var appTrace: CaptureAppTrace?
        public var warnings: WarningSummary
        public var diagnosticsWarnings: [String]?

        enum CodingKeys: String, CodingKey {
            case scenario
            case durationSeconds = "duration_seconds"
            case processID = "process_id"
            case exitStatus = "exit_status"
            case endReason = "end_reason"
            case launchedProcessPath = "launched_process_path"
            case logRelpath = "log_relpath"
            case stdoutRelpath = "stdout_relpath"
            case stderrRelpath = "stderr_relpath"
            case appTraceRelpath = "app_trace_relpath"
            case appTrace = "app_trace"
            case warnings
            case diagnosticsWarnings = "diagnostics_warnings"
        }
    }

    public struct Summary: Codable, Equatable {
        public var mode: String
        public var captures: [Report]
    }

    public struct Capture {
        public var record: ManifestBuilder.CaptureRecord
        public var report: Report
    }

    public static func record(
        _ inputs: ScenarioInputs,
        processList: (() throws -> String)? = nil,
        sleeper: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        terminator: (Int32) -> Void = { _ = Darwin.kill($0, SIGTERM) }
    ) throws -> Capture {
        let fm = FileManager.default
        try fm.createDirectory(at: inputs.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: inputs.daemonDataHome, withIntermediateDirectories: true)
        fm.createFile(atPath: inputs.stdoutURL.path, contents: nil)
        fm.createFile(atPath: inputs.stderrURL.path, contents: nil)

        let (openCommand, openArguments) = openCommand(inputs)
        let openResult = try ProcessRunner.run(openCommand, arguments: openArguments)
        guard openResult.exitStatus == 0 else {
            try writeCombinedLog(
                to: inputs.logURL,
                sections: [
                    ("open stdout", openResult.stdoutString),
                    ("open stderr", openResult.stderrString),
                ]
            )
            throw Failure(message: "open failed for \(inputs.scenario): \(openResult.stderrString)")
        }

        let processID = try waitForLaunchedProcessID(
            matching: inputs.hostBinaryPath.path,
            processList: processList ?? { try currentProcessList() },
            sleeper: sleeper
        )

        sleeper(TimeInterval(inputs.durationSeconds))
        terminator(processID)
        sleeper(0.5)

        let (logCommand, logArguments) = logShowCommand(
            processID: processID,
            windowSeconds: max(inputs.durationSeconds + 30, 45)
        )
        let logResult = try ProcessRunner.run(logCommand, arguments: logArguments)
        let logText = logResult.stdoutString
        let stdoutText = (try? String(contentsOf: inputs.stdoutURL, encoding: .utf8)) ?? ""
        let stderrText = (try? String(contentsOf: inputs.stderrURL, encoding: .utf8)) ?? ""
        let warnings = warningSummary(
            in: [logText, logResult.stderrString, stdoutText, stderrText].joined(separator: "\n")
        )
        try writeCombinedLog(
            to: inputs.logURL,
            sections: [
                ("open command", ([openCommand] + openArguments).joined(separator: " ")),
                ("open stdout", openResult.stdoutString),
                ("open stderr", openResult.stderrString),
                ("log show stdout", logText),
                ("log show stderr", logResult.stderrString),
                ("process stdout", stdoutText),
                ("process stderr", stderrText),
            ]
        )

        let logRelpath = relativePath(from: inputs.runDir, to: inputs.logURL)
        let stdoutRelpath = relativePath(from: inputs.runDir, to: inputs.stdoutURL)
        let stderrRelpath = relativePath(from: inputs.runDir, to: inputs.stderrURL)
        let exitStatus = logResult.exitStatus == 0 ? Int32(0) : logResult.exitStatus
        var diagnosticsWarnings: [String] = []
        let appTrace: CaptureAppTrace? = {
            guard let appTraceRelpath = inputs.appTraceRelpath else { return nil }
            let appTraceURL = AuditArtifactPaths.appTraceURL(runDir: inputs.runDir, relpath: appTraceRelpath)
            guard FileManager.default.fileExists(atPath: appTraceURL.path) else {
                diagnosticsWarnings.append("app-trace file missing: \(appTraceRelpath)")
                return nil
            }
            do {
                return try AppTraceParser.summarize(fileURL: appTraceURL, relpath: appTraceRelpath)
            } catch {
                diagnosticsWarnings.append("app-trace parse failed: \(appTraceRelpath)")
                return nil
            }
        }()
        let report = Report(
            scenario: inputs.scenario,
            durationSeconds: inputs.durationSeconds,
            processID: processID,
            exitStatus: exitStatus,
            endReason: logResult.exitStatus == 0 ? "log-only completed" : "log-show failed",
            launchedProcessPath: inputs.hostBinaryPath.path,
            logRelpath: logRelpath,
            stdoutRelpath: stdoutRelpath,
            stderrRelpath: stderrRelpath,
            appTraceRelpath: inputs.appTraceRelpath,
            appTrace: appTrace,
            warnings: warnings,
            diagnosticsWarnings: diagnosticsWarnings.isEmpty ? nil : diagnosticsWarnings
        )
        let captureRecord = ManifestBuilder.CaptureRecord(
            scenario: inputs.scenario,
            template: templateName,
            durationSeconds: inputs.durationSeconds,
            traceRelpath: logRelpath,
            appTraceRelpath: inputs.appTraceRelpath,
            exitStatus: Int(report.exitStatus),
            endReason: report.endReason,
            previewScenario: inputs.previewScenario,
            launchedProcessPath: inputs.hostBinaryPath.path,
            daemonDataHome: inputs.daemonDataHome.path,
            daemonDataHomeProbe: DaemonDataHomeProbe.capture(
                dataHome: inputs.daemonDataHomeProbe ?? inputs.daemonDataHome
            )
        )
        return Capture(record: captureRecord, report: report)
    }

    public static func openCommand(_ inputs: ScenarioInputs) -> (command: String, arguments: [String]) {
        var arguments = [
            "-n",
            "-j",
            "--stdout", inputs.stdoutURL.path,
            "--stderr", inputs.stderrURL.path,
        ]
        for (key, value) in inputs.environment.sorted(by: { $0.key < $1.key }) {
            arguments += ["--env", "\(key)=\(value)"]
        }
        arguments += [inputs.hostAppPath.path, "--args"]
        arguments += inputs.launchArguments
        return ("/usr/bin/open", arguments)
    }

    public static func logShowCommand(
        processID: Int32,
        windowSeconds: Int
    ) -> (command: String, arguments: [String]) {
        let predicate = [
            "processID == \(processID)",
            "!((subsystem == \"com.apple.corespotlight\") && (eventMessage CONTAINS[c] \"MailCS\"))",
        ].joined(separator: " && ")
        return (
            "/usr/bin/log",
            [
                "show",
                "--last", "\(windowSeconds)s",
                "--style", "compact",
                "--info",
                "--debug",
                "--predicate", predicate,
            ]
        )
    }

    public static func processIDs(in psOutput: String, matching binaryPath: String) -> [Int32] {
        psOutput.split(separator: "\n").compactMap { line -> Int32? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstSpace = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                return nil
            }
            let pidText = String(trimmed[..<firstSpace])
            let command = trimmed[firstSpace...].trimmingCharacters(in: .whitespaces)
            guard command.contains(binaryPath) else { return nil }
            return Int32(pidText)
        }
    }

    public static func warningSummary(in logText: String) -> WarningSummary {
        LogWarningClassifier.summary(in: logText)
    }

    public static func writeSummary(_ summary: Summary, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        try data.write(to: url, options: .atomic)
    }

    private static func waitForLaunchedProcessID(
        matching binaryPath: String,
        processList: () throws -> String,
        sleeper: (TimeInterval) -> Void
    ) throws -> Int32 {
        for _ in 0..<30 {
            let ids = processIDs(in: try processList(), matching: binaryPath)
            if let id = ids.first { return id }
            sleeper(0.2)
        }
        throw Failure(message: "Timed out waiting for launched audit host at \(binaryPath)")
    }

    private static func currentProcessList() throws -> String {
        try ProcessRunner.runChecked("/bin/ps", arguments: ["-Ao", "pid=,command="]).stdoutString
    }

    private static func writeCombinedLog(to url: URL, sections: [(String, String)]) throws {
        var text = ""
        for (label, body) in sections {
            guard !body.isEmpty else { continue }
            text += "[\(label)]\n"
            text += body
            if !body.hasSuffix("\n") { text += "\n" }
            text += "\n"
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func relativePath(from base: URL, to file: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let filePath = file.standardizedFileURL.path
        if filePath.hasPrefix(basePath + "/") {
            return String(filePath.dropFirst(basePath.count + 1))
        }
        return filePath
    }
}
