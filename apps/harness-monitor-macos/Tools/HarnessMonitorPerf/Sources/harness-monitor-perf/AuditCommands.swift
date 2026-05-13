import ArgumentParser
import Darwin
import Foundation
import HarnessMonitorPerfCore

struct Audit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Run the full Instruments audit pipeline."
    )

    @Option(name: .long, help: "Run label.")
    var label: String

    @Option(name: [.long, .customLong("compare-to")], help: "Optional baseline run dir or summary.json.")
    var compareTo: String?

    @Option(name: .long, help: "Scenario selection: all or comma list. Default: all")
    var scenarios: String = "all"

    @Flag(name: [.long, .customLong("keep-traces")], help: "Keep raw .trace bundles.")
    var keepTraces: Bool = false

    @Flag(
        name: [.long, .customLong("debug-retention")],
        help: "Keep traces, launch sidecars, and raw export XML for diagnosis."
    )
    var debugRetention: Bool = false

    @Option(name: [.long, .customLong("checkout-root")], help: "Repo checkout root.")
    var checkoutRoot: String

    @Option(name: [.long, .customLong("common-repo-root")], help: "Common repo root for runs/staged-host.")
    var commonRepoRoot: String

    @Option(name: [.long, .customLong("app-root")], help: "apps/harness-monitor-macos absolute path.")
    var appRoot: String

    @Option(name: [.long, .customLong("xcodebuild-runner")], help: "Path to monitor-xcodebuild.sh wrapper.")
    var xcodebuildRunner: String

    @Option(name: [.long, .customLong("destination")], help: "xcodebuild -destination string.")
    var destination: String

    @Option(name: [.long, .customLong("derived-data-path")], help: "DerivedData path for audit builds.")
    var derivedDataPath: String

    @Option(name: [.long, .customLong("runs-root")], help: "Runs root directory.")
    var runsRoot: String

    @Option(name: [.long, .customLong("staged-host-root")], help: "Staging directory for the launch host.")
    var stagedHostRoot: String

    @Option(name: [.long, .customLong("daemon-cargo-target-dir")], help: "Cargo target dir for the audit daemon helper.")
    var daemonCargoTargetDir: String

    @Option(name: .long, help: "Build arch.")
    var arch: String = ProcessInfo.processInfo.environment[
        "HARNESS_MONITOR_AUDIT_BUILD_ARCH"
    ] ?? Self.unameMachine()

    @Flag(name: [.long, .customLong("skip-build")], help: "Skip the Release build step.")
    var skipBuild: Bool = false

    @Flag(name: [.long, .customLong("skip-daemon-bundle")], help: "Skip rebundling the daemon helper.")
    var skipDaemonBundle: Bool = false

    @Flag(name: [.long, .customLong("force-clean")], help: "Force a clean rebuild.")
    var forceClean: Bool = false

    @Flag(name: [.long, .customLong("build-shipping")], help: "Also build the shipping app.")
    var buildShipping: Bool = false

    @Flag(name: .long, help: "Launch scenarios and capture unified logs without xctrace metrics.")
    var logOnly: Bool = false

    func run() throws {
        do {
            let outcome = try AuditRunner.run(inputs())
            print("Artifacts written to \(outcome.runDir.path)")
            print("Summary: \(outcome.summaryPath.path)")
            if let comparisonPath = outcome.comparisonPath {
                print("Comparison: \(comparisonPath.path)")
            }
        } catch let failure as AuditRunner.Failure {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
            throw ExitCode(1)
        }
    }

    private func inputs() -> AuditRunner.Inputs {
        AuditRunner.Inputs(
            label: label,
            compareTo: compareTo.map { URL(fileURLWithPath: $0) },
            scenarioSelection: scenarios,
            keepTraces: keepTraces,
            debugRetention: debugRetention,
            checkoutRoot: URL(fileURLWithPath: checkoutRoot),
            commonRepoRoot: URL(fileURLWithPath: commonRepoRoot),
            appRoot: URL(fileURLWithPath: appRoot),
            xcodebuildRunner: URL(fileURLWithPath: xcodebuildRunner),
            derivedDataPath: URL(fileURLWithPath: derivedDataPath),
            runsRoot: URL(fileURLWithPath: runsRoot),
            stagedHostStageRoot: URL(fileURLWithPath: stagedHostRoot),
            auditDaemonCargoTargetDir: URL(fileURLWithPath: daemonCargoTargetDir),
            arch: arch,
            destination: destination,
            skipBuild: skipBuild,
            skipDaemonBundle: skipDaemonBundle,
            forceClean: forceClean,
            buildShipping: buildShipping,
            logOnly: logOnly
        )
    }

    private static func unameMachine() -> String {
        var sysinfo = utsname()
        guard uname(&sysinfo) == 0 else { return "arm64" }
        let capacity = MemoryLayout.size(ofValue: sysinfo.machine)
        let machine = withUnsafePointer(to: &sysinfo.machine) { pointer -> String in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
        return machine.isEmpty ? "arm64" : machine
    }
}

struct AuditFromRef: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit-from-ref",
        abstract: "Run the audit pipeline against a checked-out git ref via a temporary worktree."
    )

    @Option(name: .long, help: "Git commit-ish to audit.")
    var ref: String

    @Option(name: .long, help: "Run label (forwarded to audit).")
    var label: String

    @Option(name: [.long, .customLong("checkout-root")], help: "Repo root that owns the worktree.")
    var checkoutRoot: String

    @Option(name: [.long, .customLong("worktree-root")], help: "Parent dir for the temporary worktree.")
    var worktreeRoot: String = "/private/tmp"

    @Option(name: .long, parsing: .upToNextOption, help: "Extra arguments forwarded to the audit subcommand.")
    var passthrough: [String] = []

    func run() throws {
        let checkout = URL(fileURLWithPath: checkoutRoot)
        let resolved = try ProcessRunner.runChecked(
            "/usr/bin/git",
            arguments: ["-C", checkout.path, "rev-parse", "--verify", "\(ref)^{commit}"]
        ).stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        let worktreePath = try addWorktree(checkout: checkout, resolved: resolved)
        defer {
            _ = try? ProcessRunner.run(
                "/usr/bin/git",
                arguments: ["-C", checkout.path, "worktree", "remove", "--force", worktreePath.path]
            )
        }
        try runAudit(in: worktreePath, resolvedCommit: resolved)
    }

    private func addWorktree(checkout: URL, resolved: String) throws -> URL {
        let shortCommit = String(resolved.prefix(8))
        let labelSlug = label.lowercased().replacingOccurrences(
            of: "[^a-z0-9._-]+",
            with: "-",
            options: .regularExpression
        )
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression)
        let name = "harness-monitor-audit-\(shortCommit)-\(timestamp)-\(labelSlug.isEmpty ? "audit" : labelSlug)"
        let worktreePath = URL(fileURLWithPath: worktreeRoot)
            .appendingPathComponent(name, isDirectory: true)

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: worktreeRoot),
            withIntermediateDirectories: true
        )
        let addResult = try ProcessRunner.run(
            "/usr/bin/git",
            arguments: ["-C", checkout.path, "worktree", "add", "--detach", worktreePath.path, resolved]
        )
        guard addResult.exitStatus == 0 else {
            FileHandle.standardError.write(addResult.stderr)
            throw ExitCode(1)
        }
        return worktreePath
    }

    private func runAudit(in worktreePath: URL, resolvedCommit: String) throws {
        let miseBinary = try resolveMiseBinary()
        let environmentOverrides = gitSafeBareRepositoryEnvironment()
        try runMise(miseBinary, ["trust"], in: worktreePath, env: environmentOverrides)
        try runMise(miseBinary, ["run", "monitor:generate"], in: worktreePath, env: environmentOverrides)

        var auditArgs = ["run", "monitor:audit", "--", "--label", label]
        auditArgs.append(contentsOf: passthrough)
        let auditResult = try ProcessRunner.run(
            miseBinary,
            arguments: auditArgs,
            environmentOverrides: environmentOverrides,
            workingDirectory: worktreePath
        )
        FileHandle.standardOutput.write(auditResult.stdout)
        FileHandle.standardError.write(auditResult.stderr)
        if auditResult.exitStatus != 0 { throw ExitCode(auditResult.exitStatus) }

        let runDir = parseRunDir(stdout: auditResult.stdoutString)
        guard !runDir.isEmpty else {
            FileHandle.standardError.write(Data("Unable to determine audit run directory\n".utf8))
            throw ExitCode(1)
        }
        try ManifestVerifier.verify(
            manifest: URL(fileURLWithPath: runDir).appendingPathComponent("manifest.json"),
            expectedCommit: resolvedCommit
        )
        print("Verified manifest provenance for \(resolvedCommit)")
    }

    private func runMise(
        _ binary: String,
        _ arguments: [String],
        in worktreePath: URL,
        env: [String: String]
    ) throws {
        let result = try ProcessRunner.run(
            binary,
            arguments: arguments,
            environmentOverrides: env,
            workingDirectory: worktreePath
        )
        FileHandle.standardOutput.write(result.stdout)
        FileHandle.standardError.write(result.stderr)
        if result.exitStatus != 0 { throw ExitCode(result.exitStatus) }
    }

    private func parseRunDir(stdout: String) -> String {
        var last = ""
        for line in stdout.split(separator: "\n") {
            let prefix = "Artifacts written to "
            if line.hasPrefix(prefix) {
                last = String(line.dropFirst(prefix.count))
            }
        }
        return last
    }

    private func resolveMiseBinary() throws -> String {
        let result = try ProcessRunner.runChecked("/usr/bin/which", arguments: ["mise"])
        let path = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            FileHandle.standardError.write(Data("Unable to resolve mise on PATH\n".utf8))
            throw ExitCode(1)
        }
        return path
    }

    private func gitSafeBareRepositoryEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let nextIndex = Int(inherited["GIT_CONFIG_COUNT"] ?? "") ?? 0
        return [
            "GIT_CONFIG_COUNT": String(nextIndex + 1),
            "GIT_CONFIG_KEY_\(nextIndex)": "safe.bareRepository",
            "GIT_CONFIG_VALUE_\(nextIndex)": "all",
        ]
    }
}
