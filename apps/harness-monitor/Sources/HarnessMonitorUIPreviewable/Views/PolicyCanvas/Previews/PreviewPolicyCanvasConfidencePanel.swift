import HarnessMonitorKit
import HarnessMonitorPolicyModels
import SwiftUI

#Preview("Policy canvas confidence panel") {
  PolicyCanvasConfidencePanel(
    viewModel: confidencePanelPreviewViewModel(),
    focusIssue: { _ in },
    focusDecision: { _ in },
    addScenario: {},
    editScenario: { _ in },
    deleteScenario: { _ in },
    resetScenarios: {},
    loadReplay: {}
  )
  .frame(width: 420)
  .padding(24)
}

@MainActor
private func confidencePanelPreviewViewModel() -> PolicyCanvasViewModel {
  let viewModel = PolicyCanvasViewModel.sample()
  viewModel.latestSimulation = PolicyPipelineSimulationResult(
    revision: 7,
    traceId: "trace-preview-confidence",
    simulatedAt: "2026-06-20T10:00:00Z",
    succeeded: true,
    validation: PolicyPipelineValidation(isValid: true),
    decisions: [
      confidencePanelPreviewDecision(
        scenarioId: "scenario-merge",
        scenarioName: "Merge - checks green",
        action: .mergePr,
        decision: PolicySimulationDecision(
          decision: "allow",
          reasonCode: "auto_merge_allowed",
          policyVersion: "v1"
        ),
        visitedNodeIds: ["policy-source", "risk-score", "context-map"]
      ),
      confidencePanelPreviewDecision(
        scenarioId: "scenario-secret",
        scenarioName: "Access secret",
        action: .accessSecret,
        decision: PolicySimulationDecision(
          decision: "deny",
          reasonCode: "risk_above_threshold",
          policyVersion: "v1"
        ),
        visitedNodeIds: ["policy-source", "risk-score"]
      ),
    ]
  )
  viewModel.latestReplay = PolicyPipelineReplayResult(
    sampleSize: 2,
    changedCount: 1,
    decisions: [
      PolicyPipelineReplayDecision(
        id: "decision-1",
        recordedAt: "2026-06-20T09:55:00Z",
        action: .mergePr,
        historicalDecision: .allow(reasonCode: .autoMergeAllowed, policyVersion: "v1"),
        draftDecision: .deny(reasonCode: .riskAboveThreshold, policyVersion: "v1"),
        visitedNodeIds: ["policy-source", "risk-score"],
        changed: true,
        insufficientEvidence: false
      )
    ]
  )
  return viewModel
}

private func confidencePanelPreviewDecision(
  scenarioId: String,
  scenarioName: String,
  action: PolicyAction,
  decision: PolicySimulationDecision,
  visitedNodeIds: [String]
) -> PolicyPipelineSimulatedDecision {
  PolicyPipelineSimulatedDecision(
    scenarioId: scenarioId,
    scenarioName: scenarioName,
    action: action,
    decision: decision,
    visitedNodeIds: visitedNodeIds
  )
}
