import Foundation

/// Builds and runs `xcrun xctrace record` per scenario, mirroring the audit script's capture
/// loop including TMPDIR scoping, --env propagation, --launch -- bundle args, and TOC export
/// for end-reason / launched-process verification.
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
        public var hostAppPath: URL
        public var hostBinaryPath: URL
        public var launchArguments: [String]
        public var environment: [String: String]
        public var traceURL: URL
        public var tocURL: URL
        public var logURL: URL
        public var daemonDataHome: URL
        public var xctraceTempRoot: URL

        public init(
            scenario: String, template: String, previewScenario: String,
            durationSeconds: Int, hostAppPath: URL, hostBinaryPath: URL,
            launchArguments: [String], environment: [String: String],
            traceURL: URL, tocURL: URL, logURL: URL, daemonDataHome: URL,
            xctraceTempRoot: URL
        ) {
            self.scenario = scenario
            self.template = template
            self.previewScenario = previewScenario
            self.durationSeconds = durationSeconds
            self.hostAppPath = hostAppPath
            self.hostBinaryPath = hostBinaryPath
            self.launchArguments = launchArguments
            self.environment = environment
            self.traceURL = traceURL
            self.tocURL = tocURL
            self.logURL = logURL
            self.daemonDataHome = daemonDataHome
            self.xctraceTempRoot = xctraceTempRoot
        }
    }

    /// Returns the `xcrun xctrace record ...` command + args without launching the process,
    /// for unit tests and dry-run mode. Args order matches run-instruments-audit.sh:886.
    public static func recordCommand(_ inputs: ScenarioInputs) -> (command: String, arguments: [String]) {
        var arguments: [String] = ["xctrace", "record"]
        arguments += ["--template", inputs.template]
        arguments += ["--time-limit", "\(inputs.durationSeconds)s"]
        arguments += ["--output", inputs.traceURL.path]
        for (key, value) in inputs.environment.sorted(by: { $0.key < $1.key }) {
            arguments += ["--env", "\(key)=\(value)"]
        }
        arguments += ["--launch", "--", inputs.hostAppPath.path]
        arguments += inputs.launchArguments
        return ("/usr/bin/xcrun", arguments)
    }

    public static func exportTOCCommand(traceURL: URL, tocURL: URL) -> (command: String, arguments: [String]) {
        ("/usr/bin/xcrun", ["xctrace", "export", "--input", traceURL.path, "--toc"])
    }

    public struct Capture {
        public var record: ManifestBuilder.CaptureRecord
        public var endReason: String
        public var launchedProcessPath: String
    }

    /// Records one scenario, exports TOC, validates launched-process, and returns a populated
    /// CaptureRecord. Throws on hard failures (missing trace bundle, unexpected launch path,
    /// xctrace exit non-zero with non-time-limit end reason).
    public static func record(
        _ inputs: ScenarioInputs,
        afterRecordHook: (() throws -> Void)? = nil
    ) throws -> Capture {
        let fm = FileManager.default
        try fm.createDirectory(at: inputs.traceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: inputs.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: inputs.xctraceTempRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: inputs.daemonDataHome, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: inputs.logURL.path) {
            fm.createFile(atPath: inputs.logURL.path, contents: nil)
        }

        let (command, arguments) = recordCommand(inputs)
        let recordResult = try ProcessRunner.run(
            command, arguments: arguments,
            environmentOverrides: ["TMPDIR": inputs.xctraceTempRoot.path + "/"]
        )

        try? appendLog(inputs.logURL, label: "[record stdout]", data: recordResult.stdout)
        try? appendLog(inputs.logURL, label: "[record stderr]", data: recordResult.stderr)

        guard fm.fileExists(atPath: inputs.traceURL.path) else {
            throw Failure(message: "Trace bundle missing for \(inputs.template) / \(inputs.scenario)")
        }

        let (exportCommand, exportArgs) = exportTOCCommand(traceURL: inputs.traceURL, tocURL: inputs.tocURL)
        let exportResult = try ProcessRunner.run(
            exportCommand, arguments: exportArgs,
            environmentOverrides: ["TMPDIR": inputs.xctraceTempRoot.path + "/"]
        )
        try exportResult.stdout.write(to: inputs.tocURL, options: .atomic)
        try? appendLog(inputs.logURL, label: "[toc stderr]", data: exportResult.stderr)

        let toc = try XctraceTOC(path: inputs.tocURL)
        let endReason = toc.endReason()
        let launchedProcessPath = toc.launchedProcessPath()

        if recordResult.exitStatus != 0 && endReason != "Time limit reached" {
            throw Failure(
                message: "xctrace record failed for \(inputs.template) / \(inputs.scenario) "
                    + "with exit \(recordResult.exitStatus) and end reason \"\(endReason)\""
            )
        }

        let acceptable: Set<String> = [inputs.hostAppPath.path, inputs.hostBinaryPath.path]
        if !acceptable.contains(launchedProcessPath) {
            throw Failure(
                message: "xctrace launched unexpected app for \(inputs.template) / \(inputs.scenario): "
                    + "expected \(inputs.hostAppPath.path) or \(inputs.hostBinaryPath.path) "
                    + "but trace recorded \(launchedProcessPath.isEmpty ? "<missing>" : launchedProcessPath)"
            )
        }

        try afterRecordHook?()

        let runDirAnchor = inputs.traceURL.deletingLastPathComponent().deletingLastPathComponent()
        let traceRel = relativePath(from: runDirAnchor, to: inputs.traceURL)
        let captureRecord = ManifestBuilder.CaptureRecord(
            scenario: inputs.scenario,
            template: inputs.template,
            durationSeconds: inputs.durationSeconds,
            traceRelpath: traceRel,
            exitStatus: Int(recordResult.exitStatus),
            endReason: endReason,
            previewScenario: inputs.previewScenario,
            launchedProcessPath: launchedProcessPath,
            daemonDataHome: inputs.daemonDataHome.path
        )
        return Capture(record: captureRecord, endReason: endReason, launchedProcessPath: launchedProcessPath)
    }

    private static func appendLog(_ url: URL, label: String, data: Data) throws {
        if data.isEmpty { return }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((label + "\n").utf8))
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\n".utf8))
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
