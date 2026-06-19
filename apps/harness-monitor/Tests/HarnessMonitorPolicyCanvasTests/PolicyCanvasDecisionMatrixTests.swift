import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
import HarnessMonitorPolicyModels

/// Phase 3 confidence panel: the decision-matrix projection over the latest
/// simulation, plus the verdict-string mapping that distinguishes needs-human
/// and consensus from a plain deny.
@Suite("Policy canvas decision matrix")
@MainActor
struct PolicyCanvasDecisionMatrixTests {
  @Test("Verdict strings map to the five terminal verdicts")
  func verdictMapping() {
    #expect(PolicyCanvasDecisionVerdict(decisionString: "allow") == .allow)
    #expect(PolicyCanvasDecisionVerdict(decisionString: "deny") == .deny)
    #expect(PolicyCanvasDecisionVerdict(decisionString: "require_human") == .needsHuman)
    #expect(PolicyCanvasDecisionVerdict(decisionString: "require_consensus") == .consensus)
    #expect(PolicyCanvasDecisionVerdict(decisionString: "dry_run_only") == .dryRun)
    #expect(PolicyCanvasDecisionVerdict(decisionString: "weird") == .unknown("weird"))
  }

  @Test("Decision matrix rows project from the latest simulation")
  func rowsProjectFromSimulation() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.latestSimulation = simulation(
      succeeded: true,
      decisions: [
        decision(action: .mergePr, verdict: "allow", reason: "default_allow", visited: ["a", "b"]),
        decision(action: .accessSecret, verdict: "deny", reason: "checks_not_green", visited: ["c"]),
        decision(action: .spawnAgent, verdict: "require_human", reason: "human_required", visited: []),
      ]
    )

    let rows = viewModel.decisionMatrixRows
    #expect(rows.count == 3)
    #expect(rows[0].actionRaw == "merge_pr")
    #expect(rows[0].actionTitle == "merge pr")
    #expect(rows[0].verdict == .allow)
    #expect(rows[0].reasonCode == "default_allow")
    #expect(rows[0].visitedNodeIds == ["a", "b"])
    #expect(rows[1].verdict == .deny)
    #expect(rows[2].verdict == .needsHuman)
  }

  @Test("A failed simulation yields no decision rows")
  func failedSimulationHasNoRows() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.latestSimulation = simulation(
      succeeded: false,
      decisions: [decision(action: .mergePr, verdict: "allow", reason: "default_allow", visited: ["a"])]
    )

    #expect(viewModel.decisionMatrixRows.isEmpty)
  }

  @Test("No simulation yields no decision rows")
  func noSimulationHasNoRows() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    #expect(viewModel.decisionMatrixRows.isEmpty)
  }

  private func decision(
    action: PolicyAction,
    verdict: String,
    reason: String,
    visited: [String]
  ) -> TaskBoardPolicyPipelineSimulatedDecision {
    TaskBoardPolicyPipelineSimulatedDecision(
      action: action,
      decision: TaskBoardPolicyDecision(decision: verdict, reasonCode: reason, policyVersion: "v1"),
      visitedNodeIds: visited
    )
  }

  private func simulation(
    succeeded: Bool,
    decisions: [TaskBoardPolicyPipelineSimulatedDecision]
  ) -> TaskBoardPolicyPipelineSimulationResult {
    TaskBoardPolicyPipelineSimulationResult(
      revision: 1,
      traceId: "trace-test",
      simulatedAt: "2026-06-19T00:00:00Z",
      succeeded: succeeded,
      validation: TaskBoardPolicyPipelineValidation(isValid: succeeded),
      decisions: decisions
    )
  }
}
