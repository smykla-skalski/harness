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
        abstract: "Run the full Instruments audit pipeline (not yet implemented)."
    )
    func run() throws { throw ExitCode(2) }
}

struct AuditFromRef: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit-from-ref",
        abstract: "Run the audit pipeline against a checked-out git ref (not yet implemented)."
    )
    func run() throws { throw ExitCode(2) }
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
