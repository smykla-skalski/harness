import ArgumentParser
import Foundation
import HarnessMonitorPerfCore

struct AuditBisect: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit-bisect",
        abstract: "Find the first budget-failing commit with git bisect in a temporary worktree."
    )

    @Option(name: [.long, .customLong("good-ref")], help: "Known-good git commit-ish.")
    var goodRef: String

    @Option(name: [.long, .customLong("bad-ref")], help: "Known-bad git commit-ish.")
    var badRef: String

    @Option(name: .long, help: "Audit label prefix.")
    var label: String

    @Option(name: [.long, .customLong("checkout-root")], help: "Repo root that owns the worktree.")
    var checkoutRoot: String

    @Option(name: [.long, .customLong("worktree-root")], help: "Parent dir for the temporary bisect worktree.")
    var worktreeRoot: String = "/private/tmp"

    @Option(name: .long, parsing: .upToNextOption, help: "Extra arguments forwarded to monitor:audit.")
    var passthrough: [String] = []

    @Flag(name: .long, help: "Print the planned worktree, runner, and commands without running git bisect.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Keep the temporary bisect worktree after completion.")
    var keepWorktree: Bool = false

    func run() throws {
        do {
            let outcome = try AuditBisectRunner.run(inputs())
            if dryRun {
                try printPlan(outcome.plan)
                print(AuditBisectRunner.runnerScript(
                    label: outcome.plan.label,
                    passthroughArguments: outcome.plan.passthroughArguments
                ))
                return
            }
            FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
            FileHandle.standardError.write(Data(outcome.stderr.utf8))
            if outcome.exitStatus != 0 {
                throw ExitCode(outcome.exitStatus)
            }
        } catch let failure as AuditBisectRunner.Failure {
            FileHandle.standardError.write(Data((failure.message + "\n").utf8))
            throw ExitCode(1)
        }
    }

    private func inputs() -> AuditBisectRunner.Inputs {
        AuditBisectRunner.Inputs(
            checkoutRoot: URL(fileURLWithPath: checkoutRoot),
            worktreeRoot: URL(fileURLWithPath: worktreeRoot),
            goodRef: goodRef,
            badRef: badRef,
            label: label,
            passthroughArguments: passthrough,
            dryRun: dryRun,
            keepWorktree: keepWorktree
        )
    }

    private func printPlan(_ plan: AuditBisectRunner.Plan) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(plan))
        FileHandle.standardOutput.write(Data("\n--- runner script ---\n".utf8))
    }
}
