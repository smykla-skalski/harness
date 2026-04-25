import Foundation

/// Builds and runs `xcrun xctrace record` per scenario, mirroring the audit script's capture
/// loop. Returns a populated `ManifestBuilder.CaptureRecord` for each scenario.
public enum TraceRecorder {
    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public struct ScenarioInputs {
        public var scenario: String
        public var template: String
        public var previewScenario: String
        public var durationSeconds: Int
        public var hostBinary: URL
        public var launchArguments: [String]
        public var environment: [String: String]
        public var traceURL: URL
        public var logURL: URL
        public var daemonDataHome: URL

        public init(
            scenario: String, template: String, previewScenario: String,
            durationSeconds: Int, hostBinary: URL, launchArguments: [String],
            environment: [String: String], traceURL: URL, logURL: URL, daemonDataHome: URL
        ) {
            self.scenario = scenario
            self.template = template
            self.previewScenario = previewScenario
            self.durationSeconds = durationSeconds
            self.hostBinary = hostBinary
            self.launchArguments = launchArguments
            self.environment = environment
            self.traceURL = traceURL
            self.logURL = logURL
            self.daemonDataHome = daemonDataHome
        }
    }

    /// Returns the `xcrun xctrace record ...` command + args without launching the process,
    /// for unit tests and dry-run mode.
    public static func recordCommand(_ inputs: ScenarioInputs) -> (command: String, arguments: [String]) {
        var arguments: [String] = ["xctrace", "record"]
        arguments += ["--template", inputs.template]
        arguments += ["--time-limit", "\(inputs.durationSeconds)s"]
        arguments += ["--launch", inputs.hostBinary.path]
        arguments += ["--output", inputs.traceURL.path]
        for argument in inputs.launchArguments {
            arguments += ["--", argument]
        }
        return ("/usr/bin/xcrun", arguments)
    }

    /// Records a trace by invoking xctrace and streaming stdout/stderr into `inputs.logURL`.
    /// Returns the capture record for ManifestBuilder.
    public static func record(_ inputs: ScenarioInputs) throws -> ManifestBuilder.CaptureRecord {
        try FileManager.default.createDirectory(
            at: inputs.traceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: inputs.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: inputs.logURL.path) {
            FileManager.default.createFile(atPath: inputs.logURL.path, contents: nil)
        }

        let (command, arguments) = recordCommand(inputs)
        let started = Date()
        let result = try ProcessRunner.run(
            command, arguments: arguments,
            environmentOverrides: inputs.environment
        )
        let duration = Date().timeIntervalSince(started)

        let log = inputs.logURL
        try? Data(result.stdout).write(to: log, options: .atomic)
        if let handle = try? FileHandle(forWritingTo: log) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\n[stderr]\n".utf8))
            try? handle.write(contentsOf: result.stderr)
            try? handle.close()
        }

        let endReason: String = result.exitStatus == 0 ? "completed" : "failed"
        let traceRelpath = inputs.traceURL.lastPathComponent
        return ManifestBuilder.CaptureRecord(
            scenario: inputs.scenario,
            template: inputs.template,
            durationSeconds: Int(duration.rounded()),
            traceRelpath: traceRelpath,
            exitStatus: Int(result.exitStatus),
            endReason: endReason,
            previewScenario: inputs.previewScenario,
            launchedProcessPath: inputs.hostBinary.path,
            daemonDataHome: inputs.daemonDataHome.path
        )
    }
}
