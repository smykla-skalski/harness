import XCTest
@testable import HarnessMonitorPerfCore

final class AuditBisectRunnerTests: XCTestCase {
    func testPlanKeepsBisectInsideTemporaryWorktree() {
        let inputs = AuditBisectRunner.Inputs(
            checkoutRoot: URL(fileURLWithPath: "/repo"),
            worktreeRoot: URL(fileURLWithPath: "/tmp"),
            goodRef: "good",
            badRef: "bad",
            label: "Sidebar Matrix",
            passthroughArguments: ["--scenarios", "search-suggestions"],
            dryRun: true
        )

        let plan = AuditBisectRunner.makePlan(
            inputs: inputs,
            goodCommit: "1111111111111111111111111111111111111111",
            badCommit: "2222222222222222222222222222222222222222",
            timestamp: "20260514T084500Z"
        )

        XCTAssertEqual(plan.label, "Sidebar Matrix")
        XCTAssertTrue(plan.worktreePath.contains("/tmp/harness-monitor-bisect-22222222-20260514T084500Z-Sidebar-Matrix"))
        XCTAssertEqual(plan.commands.count, 3)
        XCTAssertEqual(Array(plan.commands[0].suffix(2)), [plan.worktreePath, plan.badCommit])
        XCTAssertEqual(plan.commands[1], [
            "/usr/bin/git", "-C", plan.worktreePath,
            "bisect", "start", plan.badCommit, plan.goodCommit,
        ])
        XCTAssertEqual(plan.commands[2], [
            "/usr/bin/git", "-C", plan.worktreePath,
            "bisect", "run", plan.runnerScriptPath,
        ])
    }

    func testRunnerScriptTreatsInfrastructureFailuresAsSkipAndBudgetFailuresAsBad() {
        let script = AuditBisectRunner.runnerScript(
            label: "perf bisect",
            passthroughArguments: ["--scenarios", "search'suggestions"]
        )

        XCTAssertTrue(script.contains("mise run monitor:audit -- --label 'perf bisect'-\"$commit\" --skip-budget-enforcement"))
        XCTAssertTrue(script.contains("'search'\\''suggestions'"))
        XCTAssertTrue(script.contains("exit 125"))
        XCTAssertTrue(script.contains("enforce-budgets \"$summary\""))
        XCTAssertTrue(script.contains("git reset --hard --quiet"))
        XCTAssertTrue(script.contains("exit 1"))
    }
}
