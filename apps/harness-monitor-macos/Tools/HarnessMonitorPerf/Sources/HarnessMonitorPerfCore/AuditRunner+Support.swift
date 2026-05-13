import Darwin
import Foundation

extension AuditRunner {
    public static func shouldAllowExternalDaemonAudit(
        defaultEnvironment: [String: String]
    ) -> Bool {
        defaultEnvironment["HARNESS_MONITOR_LAUNCH_MODE"] == "live"
            && defaultEnvironment["HARNESS_MONITOR_EXTERNAL_DAEMON"] == "1"
    }

    public static func defaultEnvironment(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = baseEnvironment.merging(
            passThroughEnvironment(processEnvironment)
        ) { _, override in
            override
        }
        if trimmedNonEmpty(processEnvironment[daemonDataHomeOverrideEnvironmentKey]) != nil {
            if trimmedNonEmpty(environment["HARNESS_MONITOR_LAUNCH_MODE"]) == nil {
                environment["HARNESS_MONITOR_LAUNCH_MODE"] = "live"
            }
            if trimmedNonEmpty(environment["HARNESS_MONITOR_EXTERNAL_DAEMON"]) == nil {
                environment["HARNESS_MONITOR_EXTERNAL_DAEMON"] = "1"
            }
        }
        return environment
    }

    public static func daemonDataHome(
        runDir: URL,
        templateSlug: String,
        scenario: String,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = trimmedNonEmpty(
            processEnvironment[daemonDataHomeOverrideEnvironmentKey]
        ) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return runDir
            .appendingPathComponent("app-data", isDirectory: true)
            .appendingPathComponent(templateSlug, isDirectory: true)
            .appendingPathComponent(scenario, isDirectory: true)
    }

    public static func auditDaemonDataHome(
        runDir: URL,
        templateSlug: String,
        scenario: String,
        defaultEnvironment: [String: String],
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        processIsLive: ((Int32) -> Bool)? = nil
    ) throws -> AuditDaemonDataHome {
        let sourceDataHome = daemonDataHome(
            runDir: runDir,
            templateSlug: templateSlug,
            scenario: scenario,
            processEnvironment: processEnvironment
        )
        guard trimmedNonEmpty(processEnvironment[daemonDataHomeOverrideEnvironmentKey]) != nil else {
            return .init(
                launchDataHome: sourceDataHome,
                probeDataHome: sourceDataHome,
                mirroredManifest: false
            )
        }
        guard shouldAllowExternalDaemonAudit(defaultEnvironment: defaultEnvironment) else {
            throw Failure(
                message: """
                HARNESS_MONITOR_AUDIT_DAEMON_DATA_HOME requires \
                HARNESS_MONITOR_LAUNCH_MODE=live and HARNESS_MONITOR_EXTERNAL_DAEMON=1 \
                so the audit runner can mirror daemon credentials before launching \
                Harness Monitor UI Testing Audit.app.
                """
            )
        }

        let mirrorDataHome = runDir
            .appendingPathComponent("app-data-mirrors", isDirectory: true)
            .appendingPathComponent(templateSlug, isDirectory: true)
            .appendingPathComponent(scenario, isDirectory: true)
        try prepareAuditDaemonDataHomeMirror(
            sourceDataHome: sourceDataHome,
            mirrorDataHome: mirrorDataHome,
            fileManager: fileManager,
            processIsLive: processIsLive
        )
        return .init(
            launchDataHome: mirrorDataHome,
            probeDataHome: sourceDataHome,
            mirroredManifest: true
        )
    }

    public static func prepareAuditDaemonDataHomeMirror(
        sourceDataHome: URL,
        mirrorDataHome: URL,
        fileManager: FileManager = .default,
        processIsLive: ((Int32) -> Bool)? = nil
    ) throws {
        let sourceManifestURL = sourceDataHome
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("daemon", isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: sourceManifestURL.path) else {
            throw Failure(
                message: "External audit daemon manifest missing at \(sourceManifestURL.path)"
            )
        }

        let manifestData = try Data(contentsOf: sourceManifestURL)
        let rawManifest = try JSONSerialization.jsonObject(with: manifestData)
        guard var manifest = rawManifest as? [String: Any] else {
            throw Failure(
                message: "External audit daemon manifest must be a JSON object at \(sourceManifestURL.path)"
            )
        }
        try rewriteManifestTokenPath(&manifest, sourceManifestURL: sourceManifestURL)
        try validateManifestProcess(
            manifest,
            sourceManifestURL: sourceManifestURL,
            processIsLive: processIsLive
        )

        let tokenPathKey = manifest["token_path"] != nil ? "token_path" : "tokenPath"
        let sourceTokenURL = URL(
            fileURLWithPath: manifest[tokenPathKey] as? String ?? ""
        ).standardizedFileURL
        guard fileManager.fileExists(atPath: sourceTokenURL.path) else {
            throw Failure(
                message: "External audit daemon token missing at \(sourceTokenURL.path)"
            )
        }

        let mirrorDaemonRoot = mirrorDataHome
            .appendingPathComponent("harness", isDirectory: true)
            .appendingPathComponent("daemon", isDirectory: true)
        try fileManager.createDirectory(at: mirrorDaemonRoot, withIntermediateDirectories: true)

        let mirrorTokenURL = mirrorDaemonRoot.appendingPathComponent("auth-token")
        let mirrorManifestURL = mirrorDaemonRoot.appendingPathComponent("manifest.json")
        try Data(contentsOf: sourceTokenURL).write(to: mirrorTokenURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: mirrorTokenURL.path
        )

        manifest[tokenPathKey] = mirrorTokenURL.path
        let mirroredManifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        try mirroredManifestData.write(to: mirrorManifestURL, options: .atomic)
    }

    public static func validateProvenance(
        bundle: URL, label: String,
        gitCommit: String, gitDirty: String, workspaceFingerprint: String,
        allowMismatch: Bool
    ) throws {
        let commit = BuildOrchestrator.bundleProvenanceValue(
            bundle: bundle,
            key: BuildOrchestrator.buildCommitKey
        )
        let dirty = BuildOrchestrator.bundleProvenanceValue(
            bundle: bundle,
            key: BuildOrchestrator.buildDirtyKey
        )
        let fp = BuildOrchestrator.bundleProvenanceValue(
            bundle: bundle,
            key: BuildOrchestrator.buildWorkspaceFingerprintKey
        )
        if commit == gitCommit && dirty == gitDirty && fp == workspaceFingerprint { return }
        let detail = "expected commit=\(gitCommit) dirty=\(gitDirty) fingerprint=\(workspaceFingerprint) "
            + "but bundle reports commit=\(commit) dirty=\(dirty) fingerprint=\(fp)"
        if allowMismatch {
            FileHandle.standardError.write(
                Data("\(label) build provenance mismatch: \(detail). Continuing because skip-build is set.\n".utf8)
            )
            return
        }
        throw Failure(message: "\(label) build provenance mismatch: \(detail)")
    }

    public static func assertSourceUnchanged(
        checkpoint: String, checkoutRoot: URL, appRoot: URL,
        gitCommit: String, workspaceFingerprint: String
    ) throws {
        let currentCommit = try gitRevParseHead(checkoutRoot)
        let currentFingerprint = try WorkspaceFingerprint.compute(
            variant: .audit,
            projectDir: appRoot
        )
        if currentCommit == gitCommit && currentFingerprint == workspaceFingerprint { return }
        throw Failure(
            message: "Audit source changed during \(checkpoint). Built commit=\(gitCommit) fingerprint=\(workspaceFingerprint); current commit=\(currentCommit) fingerprint=\(currentFingerprint). Rerun the audit so Instruments measures the current checkout."
        )
    }

    public static func gitRevParseHead(_ root: URL) throws -> String {
        try gitOutput(root: root, arguments: ["rev-parse", "HEAD"])
    }

    public static func gitDirtyFlag(_ root: URL) throws -> String {
        let result = try ProcessRunner.run(
            "/usr/bin/git",
            arguments: ["-C", root.path, "status", "--short"]
        )
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "false"
            : "true"
    }

    public static func cleanupHostProcesses() {
        let result = (try? ProcessRunner.run(
            "/bin/ps",
            arguments: ["-Ao", "pid=,command="]
        ))?.stdoutString ?? ""
        cleanupHostProcesses(psOutput: result) { pid in
            kill(pid, SIGKILL)
        }
    }

    static func cleanupHostProcesses(psOutput: String, signal: (Int32) -> Void) {
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            let pidString = String(trimmed[..<space])
            let command = String(trimmed[trimmed.index(after: space)...])
            guard let pid = Int32(pidString) else { continue }
            if command.contains("Harness Monitor UI Testing.app/Contents/MacOS/Harness Monitor UI Testing")
                || command.contains("Harness Monitor UI Testing Audit.app/Contents/MacOS/Harness Monitor UI Testing")
                || command.contains("target/debug/harness daemon serve")
                || command.contains("target/debug/harness bridge start")
                || command.contains("/mock-codex") {
                signal(pid)
            }
        }
    }

    static func externalDaemonProcessIsLive(_ pid: Int32) -> Bool {
        errno = 0
        let result = kill(pid, 0)
        return result == 0 || errno == EPERM
    }

    static func utcCompactTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }

    static func utcExtendedTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }

    private static func rewriteManifestTokenPath(
        _ manifest: inout [String: Any],
        sourceManifestURL: URL
    ) throws {
        let tokenPathKey: String
        if manifest["token_path"] != nil {
            tokenPathKey = "token_path"
        } else if manifest["tokenPath"] != nil {
            tokenPathKey = "tokenPath"
        } else {
            throw Failure(
                message: "External audit daemon manifest has no token path at \(sourceManifestURL.path)"
            )
        }

        guard
            let sourceTokenPath = manifest[tokenPathKey] as? String,
            (sourceTokenPath as NSString).isAbsolutePath
        else {
            throw Failure(
                message: "External audit daemon manifest token path must be absolute at \(sourceManifestURL.path)"
            )
        }
    }

    private static func validateManifestProcess(
        _ manifest: [String: Any],
        sourceManifestURL: URL,
        processIsLive: ((Int32) -> Bool)?
    ) throws {
        guard let processIsLive else { return }
        guard let pid = manifestPID(manifest["pid"]) else {
            throw Failure(
                message: "External audit daemon manifest has no pid at \(sourceManifestURL.path)"
            )
        }
        guard pid > 0 else {
            throw Failure(
                message: "External audit daemon manifest pid must be positive at \(sourceManifestURL.path)"
            )
        }
        guard processIsLive(pid) else {
            throw Failure(
                message: "External audit daemon manifest pid \(pid) is not live at \(sourceManifestURL.path)"
            )
        }
    }

    private static func manifestPID(_ value: Any?) -> Int32? {
        if let number = value as? NSNumber {
            return number.int32Value
        }
        if let string = value as? String {
            return Int32(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func passThroughEnvironment(
        _ processEnvironment: [String: String]
    ) -> [String: String] {
        processEnvironment.reduce(into: [:]) { result, item in
            guard passThroughEnvironmentKeys.contains(item.key),
                  let value = trimmedNonEmpty(item.value)
            else {
                return
            }
            result[item.key] = value
        }
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func gitOutput(root: URL, arguments: [String]) throws -> String {
        let result = try ProcessRunner.runChecked(
            "/usr/bin/git",
            arguments: ["-C", root.path] + arguments
        )
        return result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
