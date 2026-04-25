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
        abstract: "Compare two completed audit runs (not yet implemented)."
    )
    func run() throws { throw ExitCode(2) }
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

struct MeasurePreviewLatency: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "measure-preview-latency",
        abstract: "Measure SwiftUI preview compile latency (not yet implemented)."
    )
    func run() throws { throw ExitCode(2) }
}
