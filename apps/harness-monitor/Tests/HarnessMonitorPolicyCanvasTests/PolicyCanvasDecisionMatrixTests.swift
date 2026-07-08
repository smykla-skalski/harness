import Foundation
import HarnessMonitorPolicyModels
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas

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

  @Test("Reason text hides verdict restatements and humanizes the rest")
  func reasonExplanation() {
    #expect(PolicyCanvasDecisionReason.explanation(reasonCode: "default_allow") == nil)
    #expect(PolicyCanvasDecisionReason.explanation(reasonCode: "human_required") == nil)
    #expect(PolicyCanvasDecisionReason.explanation(reasonCode: "dry_run_required") == nil)
    #expect(
      PolicyCanvasDecisionReason.explanation(reasonCode: "checks_not_green") == "Checks not green"
    )
    #expect(
      PolicyCanvasDecisionReason.explanation(reasonCode: "auto_merge_allowed")
        == "Auto-merge rule passed"
    )
    #expect(PolicyCanvasDecisionReason.explanation(reasonCode: "some_new_code") == "some new code")
    #expect(PolicyCanvasDecisionReason.explanation(reasonCode: "") == nil)
  }

  @Test("Decision matrix rows project from the latest simulation")
  func rowsProjectFromSimulation() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.latestSimulation = simulation(
      succeeded: true,
      decisions: [
        decision(
          scenarioId: "scenario-merge",
          scenarioName: "Merge - checks green",
          action: .mergePr,
          verdict: "allow",
          reason: "default_allow",
          visited: ["a", "b"]
        ),
        decision(
          scenarioId: "scenario-secret",
          scenarioName: "Access secret",
          action: .accessSecret,
          verdict: "deny",
          reason: "checks_not_green",
          visited: ["c"]
        ),
        decision(
          scenarioId: "scenario-agent",
          scenarioName: "Spawn agent",
          action: .spawnAgent,
          verdict: "require_human",
          reason: "human_required",
          visited: []
        ),
      ]
    )

    let rows = viewModel.decisionMatrixRows
    #expect(rows.count == 3)
    #expect(rows[0].id == "scenario-merge.merge_pr")
    #expect(rows[0].scenarioName == "Merge - checks green")
    #expect(rows[0].actionRaw == "merge_pr")
    #expect(rows[0].actionTitle == "Merge PR")
    #expect(rows[0].verdict == .allow)
    #expect(rows[0].reasonCode == "default_allow")
    #expect(rows[0].visitedNodeIds == ["a", "b"])
    #expect(rows[1].verdict == .deny)
    #expect(rows[2].verdict == .needsHuman)
  }

  @Test("Rows stay distinct when editable scenarios share an action")
  func rowsUseScenarioIdentity() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.latestSimulation = simulation(
      succeeded: true,
      decisions: [
        decision(
          scenarioId: "scenario-a",
          scenarioName: "Merge A",
          action: .mergePr,
          verdict: "allow",
          reason: "default_allow",
          visited: ["a"]
        ),
        decision(
          scenarioId: "scenario-b",
          scenarioName: "Merge B",
          action: .mergePr,
          verdict: "deny",
          reason: "checks_not_green",
          visited: ["b"]
        ),
      ]
    )

    let rows = viewModel.decisionMatrixRows

    #expect(rows.map(\.id) == ["scenario-a.merge_pr", "scenario-b.merge_pr"])
  }

  @Test("A failed simulation yields no decision rows")
  func failedSimulationHasNoRows() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.latestSimulation = simulation(
      succeeded: false,
      decisions: [
        decision(action: .mergePr, verdict: "allow", reason: "default_allow", visited: ["a"])
      ]
    )

    #expect(viewModel.decisionMatrixRows.isEmpty)
  }

  @Test("No simulation yields no decision rows")
  func noSimulationHasNoRows() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    #expect(viewModel.decisionMatrixRows.isEmpty)
  }

  private func decision(
    scenarioId: String = "",
    scenarioName: String = "",
    action: PolicyAction,
    verdict: String,
    reason: String,
    visited: [String]
  ) -> PolicyPipelineSimulatedDecision {
    PolicyPipelineSimulatedDecision(
      scenarioId: scenarioId,
      scenarioName: scenarioName,
      action: action,
      decision: PolicySimulationDecision(decision: verdict, reasonCode: reason, policyVersion: "v1"),
      visitedNodeIds: visited
    )
  }

  private func simulation(
    succeeded: Bool,
    decisions: [PolicyPipelineSimulatedDecision]
  ) -> PolicyPipelineSimulationResult {
    PolicyPipelineSimulationResult(
      revision: 1,
      traceId: "trace-test",
      simulatedAt: "2026-06-19T00:00:00Z",
      succeeded: succeeded,
      validation: PolicyPipelineValidation(isValid: succeeded),
      decisions: decisions
    )
  }
}
