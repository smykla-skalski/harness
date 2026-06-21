import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
import HarnessMonitorPolicyModels

/// Phase 6 scenario inspector: the per-scenario row projection over the latest
/// simulation, which now carries each decision's scenario id and name so the
/// inspector reads the live scenario set straight off the simulation.
@Suite("Policy canvas scenario inspector")
@MainActor
struct PolicyCanvasScenarioInspectorTests {
  @Test("Scenario rows project one row per simulated scenario")
  func rowsProjectPerScenario() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.latestSimulation = simulation(
      succeeded: true,
      decisions: [
        decision(
          id: "s1", name: "Merge - green", action: .mergePr,
          verdict: "allow", reason: "default_allow", visited: ["a", "b"]
        ),
        decision(
          id: "s2", name: "Secret - blocked", action: .accessSecret,
          verdict: "deny", reason: "checks_not_green", visited: ["c"]
        ),
      ]
    )

    let rows = viewModel.scenarioRows
    #expect(rows.count == 2)
    #expect(rows[0].id == "s1")
    #expect(rows[0].name == "Merge - green")
    #expect(rows[0].actionTitle == "Merge PR")
    #expect(rows[0].verdict == .allow)
    #expect(rows[0].visitedNodeIds == ["a", "b"])
    #expect(rows[1].id == "s2")
    #expect(rows[1].verdict == .deny)
  }

  @Test("A decision without a scenario id falls back to name and action")
  func fallbackIdentity() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.latestSimulation = simulation(
      succeeded: true,
      decisions: [
        decision(
          id: "", name: "", action: .mergePr,
          verdict: "allow", reason: "default_allow", visited: []
        )
      ]
    )

    let rows = viewModel.scenarioRows
    #expect(rows.count == 1)
    #expect(rows[0].id == "|merge_pr")
    #expect(rows[0].name == "Merge PR")
  }

  @Test("A failed simulation yields no scenario rows")
  func failedSimulationHasNoRows() {
    let viewModel = PolicyCanvasViewModel(nodes: [], groups: [], edges: [])
    viewModel.latestSimulation = simulation(
      succeeded: false,
      decisions: [
        decision(
          id: "s1", name: "Merge", action: .mergePr,
          verdict: "allow", reason: "default_allow", visited: []
        )
      ]
    )
    #expect(viewModel.scenarioRows.isEmpty)
  }

  private func decision(
    id: String,
    name: String,
    action: PolicyAction,
    verdict: String,
    reason: String,
    visited: [String]
  ) -> TaskBoardPolicyPipelineSimulatedDecision {
    TaskBoardPolicyPipelineSimulatedDecision(
      scenarioId: id,
      scenarioName: name,
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
