import ArgumentParser
import Foundation
import HarnessMonitorPerfCore

@main
struct HarnessMonitorPerf: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "harness-monitor-perf",
        abstract: "Native Instruments audit pipeline for the Harness Monitor macOS app.",
        subcommands: [
            EnforceBudgets.self,
            Audit.self,
            AuditFromRef.self,
            Compare.self,
            Summarize.self,
            Extract.self,
            Recap.self,
            DirectorySHA256.self,
            FingerprintWorkspace.self,
            TocInfo.self,
            WriteManifest.self,
            VerifyManifest.self,
            MeasurePreviewLatency.self,
        ],
        defaultSubcommand: nil
    )
}

struct EnforceBudgets: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enforce-budgets",
        abstract: "Validate a summary.json against the per-scenario performance budgets."
    )

    @Argument(help: "Path to summary.json from a completed audit run.")
    var summaryPath: String

    func run() throws {
        let url = URL(fileURLWithPath: summaryPath)
        let data = try Data(contentsOf: url)
        do {
            try BudgetEnforcer.enforce(summaryJSON: data)
        } catch let failure as BudgetEnforcer.Failure {
            FileHandle.standardError.write(Data(failure.description.utf8))
            FileHandle.standardError.write(Data("\n".utf8))
            throw ExitCode(1)
        }
    }
}

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

    @Option(name: [.long, .customLong("checkout-root")], help: "Repo checkout root.")
    var checkoutRoot: String

    @Option(name: [.long, .customLong("common-repo-root")], help: "Common repo root for runs/staged-host.")
    var commonRepoRoot: String

    @Option(name: [.long, .customLong("app-root")], help: "apps/harness-monitor-macos absolute path.")
    var appRoot: String

    @Option(name: [.long, .customLong("xcodebuild-runner")], help: "Path to xcodebuild-with-lock.sh wrapper.")
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
    var arch: String = ProcessInfo.processInfo.environment["HARNESS_MONITOR_AUDIT_BUILD_ARCH"] ?? Self.unameMachine()

    @Flag(name: [.long, .customLong("skip-build")], help: "Skip the Release build step.")
    var skipBuild: Bool = false

    @Flag(name: [.long, .customLong("skip-daemon-bundle")], help: "Skip rebundling the daemon helper.")
    var skipDaemonBundle: Bool = false

    @Flag(name: [.long, .customLong("force-clean")], help: "Force a clean rebuild.")
    var forceClean: Bool = false

    @Flag(name: [.long, .customLong("build-shipping")], help: "Also build the shipping app.")
    var buildShipping: Bool = false

    func run() throws {
        let compareToURL = compareTo.map { URL(fileURLWithPath: $0) }
        let inputs = AuditRunner.Inputs(
            label: label, compareTo: compareToURL, scenarioSelection: scenarios, keepTraces: keepTraces,
            checkoutRoot: URL(fileURLWithPath: checkoutRoot),
            commonRepoRoot: URL(fileURLWithPath: commonRepoRoot),
            appRoot: URL(fileURLWithPath: appRoot),
            xcodebuildRunner: URL(fileURLWithPath: xcodebuildRunner),
            derivedDataPath: URL(fileURLWithPath: derivedDataPath),
            runsRoot: URL(fileURLWithPath: runsRoot),
            stagedHostStageRoot: URL(fileURLWithPath: stagedHostRoot),
            auditDaemonCargoTargetDir: URL(fileURLWithPath: daemonCargoTargetDir),
            arch: arch, destination: destination,
            skipBuild: skipBuild, skipDaemonBundle: skipDaemonBundle,
            forceClean: forceClean, buildShipping: buildShipping
        )
        do {
            let outcome = try AuditRunner.run(inputs)
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

    private static func unameMachine() -> String {
        var sysinfo = utsname()
        guard uname(&sysinfo) == 0 else { return "arm64" }
        let capacity = MemoryLayout.size(ofValue: sysinfo.machine)
        let machine = withUnsafePointer(to: &sysinfo.machine) { pointer -> String in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
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

    @Option(name: [.long, .customLong("checkout-root")], help: "Repo checkout root that owns the worktree.")
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
        let shortCommit = String(resolved.prefix(8))
        let labelSlug = label.lowercased().replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: "[^A-Za-z0-9]", with: "", options: .regularExpression)
        let worktreeName = "harness-monitor-audit-\(shortCommit)-\(timestamp)-\(labelSlug.isEmpty ? "audit" : labelSlug)"
        let worktreePath = URL(fileURLWithPath: worktreeRoot).appendingPathComponent(worktreeName, isDirectory: true)

        try FileManager.default.createDirectory(at: URL(fileURLWithPath: worktreeRoot), withIntermediateDirectories: true)
        defer {
            _ = try? ProcessRunner.run(
                "/usr/bin/git",
                arguments: ["-C", checkout.path, "worktree", "remove", "--force", worktreePath.path]
            )
        }
        let addResult = try ProcessRunner.run(
            "/usr/bin/git",
            arguments: ["-C", checkout.path, "worktree", "add", "--detach", worktreePath.path, resolved]
        )
        guard addResult.exitStatus == 0 else {
            FileHandle.standardError.write(addResult.stderr)
            throw ExitCode(1)
        }
        let auditScript = worktreePath
            .appendingPathComponent("apps/harness-monitor-macos/Scripts/run-instruments-audit.sh")
        guard FileManager.default.isExecutableFile(atPath: auditScript.path) else {
            FileHandle.standardError.write(Data("Audit script not found in worktree: \(auditScript.path)\n".utf8))
            throw ExitCode(1)
        }
        var auditArgs = ["--label", label]
        auditArgs.append(contentsOf: passthrough)
        let auditResult = try ProcessRunner.run(auditScript.path, arguments: auditArgs)
        FileHandle.standardOutput.write(auditResult.stdout)
        FileHandle.standardError.write(auditResult.stderr)
        if auditResult.exitStatus != 0 { throw ExitCode(auditResult.exitStatus) }

        let runDir = parseRunDir(stdout: String(data: auditResult.stdout, encoding: .utf8) ?? "")
        guard !runDir.isEmpty else {
            FileHandle.standardError.write(Data("Unable to determine audit run directory\n".utf8))
            throw ExitCode(1)
        }
        try ManifestVerifier.verify(
            manifest: URL(fileURLWithPath: runDir).appendingPathComponent("manifest.json"),
            expectedCommit: resolved
        )
        print("Verified manifest provenance for \(resolved)")
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
}

struct Compare: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare two summary.json files and emit comparison.{json,md}."
    )

    @Option(name: .long, help: "Path to current run directory or summary.json")
    var current: String

    @Option(name: .long, help: "Path to baseline run directory or summary.json")
    var baseline: String

    @Option(name: [.long, .customLong("output-dir")], help: "Output directory for comparison.{json,md}")
    var outputDir: String

    func run() throws {
        let inputs = HarnessMonitorPerfCore.Comparator.Inputs(
            current: URL(fileURLWithPath: current),
            baseline: URL(fileURLWithPath: baseline),
            outputDir: URL(fileURLWithPath: outputDir)
        )
        do {
            _ = try HarnessMonitorPerfCore.Comparator.compare(inputs)
        } catch let failure as HarnessMonitorPerfCore.Comparator.Failure {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
            throw ExitCode(1)
        }
    }
}

struct Summarize: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summarize",
        abstract: "Render summary.json + summary.csv from manifest.json and per-capture metrics."
    )

    @Argument(help: "Path to the run directory (must contain manifest.json and metrics/).")
    var runDir: String

    func run() throws {
        let url = URL(fileURLWithPath: runDir)
        do {
            _ = try Summarizer.summarize(runDir: url)
        } catch let failure as Summarizer.Failure {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
            throw ExitCode(1)
        }
    }
}

struct Recap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recap",
        abstract: "Print a compact recap of an audit run from summary.json + comparison.json."
    )

    @Option(name: .long, help: "Run directory containing summary.json (and optional comparison.json).")
    var runDir: String

    @Option(name: [.long, .customLong("top-count")], help: "Top offenders to print per scenario. Default: 5")
    var topCount: Int = 5

    func run() throws {
        let url = URL(fileURLWithPath: runDir)
        do {
            let text = try HarnessMonitorPerfCore.Recap.render(runDir: url, topCount: topCount)
            print(text)
        } catch let failure as HarnessMonitorPerfCore.Recap.Failure {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
            throw ExitCode(1)
        }
    }
}

struct Extract: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract",
        abstract: "Export xctrace XML, parse all schemas, and write metrics + summary."
    )

    @Option(name: .long, help: "Run directory (must contain manifest.json and traces/).")
    var runDir: String

    @Option(name: .long, help: "xctrace launcher executable. Default: /usr/bin/xcrun")
    var xctrace: String = "/usr/bin/xcrun"

    @Option(name: [.long, .customLong("xctrace-args")], help: "Comma-separated args before `export ...`.")
    var xctraceArgs: String = "xctrace"

    func run() throws {
        let url = URL(fileURLWithPath: runDir)
        let tempRoot = url.appendingPathComponent("xctrace-tmp", isDirectory: true)
        let exporter = ExtractorOrchestrator.ProcessXctrace(
            command: xctrace,
            arguments: xctraceArgs.split(separator: ",").map(String.init),
            tempRoot: tempRoot
        )
        do {
            _ = try ExtractorOrchestrator.extract(runDir: url, exporter: exporter)
        } catch let failure as ExtractorOrchestrator.Failure {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
            throw ExitCode(1)
        }
    }
}

struct DirectorySHA256: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "directory-sha256",
        abstract: "Compute the {relative-path}\\0{bytes}\\0 SHA-256 hash of a directory tree."
    )

    @Argument(help: "Directory to hash.") var path: String

    func run() throws {
        let hash = try WorkspaceFingerprint.directorySHA256(URL(fileURLWithPath: path))
        print(hash)
    }
}

struct FingerprintWorkspace: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace-fingerprint",
        abstract: "SHA-256 fingerprint of the source surface for one of the known variants."
    )

    @Option(name: .long, help: "Variant: monitor-app | ui-test-host | audit")
    var variant: String

    @Option(name: [.long, .customLong("project-dir")], help: "Project root.")
    var projectDir: String

    func run() throws {
        guard let v = WorkspaceFingerprint.Variant(rawValue: variant) else {
            FileHandle.standardError.write(Data("unknown variant: \(variant)\n".utf8))
            throw ExitCode(64)
        }
        let hash = try WorkspaceFingerprint.compute(
            variant: v, projectDir: URL(fileURLWithPath: projectDir)
        )
        print(hash)
    }
}

struct TocInfo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "toc-info",
        abstract: "Read launched-process path and end-reason from a xctrace TOC XML payload."
    )

    @Argument(help: "Path to a xctrace --toc XML export.")
    var tocPath: String

    @Flag(help: "Print only the launched process path.")
    var launchedProcess: Bool = false

    @Flag(help: "Print only the end reason.")
    var endReason: Bool = false

    func run() throws {
        let toc = try XctraceTOC(path: URL(fileURLWithPath: tocPath))
        let path = toc.launchedProcessPath()
        let reason = toc.endReason()
        if launchedProcess { print(path); return }
        if endReason { print(reason); return }
        let payload: [String: String] = [
            "launched_process_path": path,
            "end_reason": reason,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

struct WriteManifest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "write-manifest",
        abstract: "Build manifest.json from an inputs JSON document and a captures TSV."
    )

    @Option(name: .long, help: "JSON document with label/run_id/git/system/targets/build_provenance/selected_scenarios.")
    var inputs: String

    @Option(name: [.long, .customLong("captures-tsv")], help: "TSV file written by the audit shell, one capture per row.")
    var capturesTsv: String

    @Option(name: [.long, .customLong("env")], parsing: .upToNextOption,
            help: "Repeated KEY=VALUE pairs that populate default_environment.")
    var env: [String] = []

    @Option(name: [.long, .customLong("launch-arg")], parsing: .upToNextOption,
            help: "Repeated launch arguments preserved in the manifest.")
    var launchArg: [String] = []

    @Option(name: .long, help: "Path where manifest.json should be written.")
    var output: String

    func run() throws {
        do {
            _ = try ManifestWriter.write(
                inputsJSON: URL(fileURLWithPath: inputs),
                capturesTSV: URL(fileURLWithPath: capturesTsv),
                environmentPairs: env,
                launchArguments: launchArg,
                output: URL(fileURLWithPath: output)
            )
        } catch let failure as ManifestWriter.Failure {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
            throw ExitCode(1)
        }
    }
}

struct VerifyManifest: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-manifest",
        abstract: "Verify manifest.json records a clean build for the expected git commit."
    )

    @Option(name: .long, help: "Path to manifest.json")
    var manifest: String

    @Option(name: [.long, .customLong("expected-commit")], help: "Expected git commit SHA.")
    var expectedCommit: String

    func run() throws {
        do {
            try ManifestVerifier.verify(
                manifest: URL(fileURLWithPath: manifest),
                expectedCommit: expectedCommit
            )
        } catch let failure as ManifestVerifier.Failure {
            FileHandle.standardError.write(Data((failure.description + "\n").utf8))
            throw ExitCode(1)
        }
    }
}

struct MeasurePreviewLatency: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "measure-preview-latency",
        abstract: "Measure SwiftUI preview JIT-link latency from `log show` markers."
    )

    @Argument(help: "Window passed to `log show --last`. Default: 15m")
    var window: String = "15m"

    func run() throws {
        do {
            let report = try PreviewLatencyMeasurer.measure(window: window)
            print(PreviewLatencyMeasurer.render(report))
        } catch let failure as PreviewLatencyMeasurer.Failure {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
            throw ExitCode(1)
        }
    }
}
