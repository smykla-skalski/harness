import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

/// Always-on confidence surface under the canvas top bar. Stacks the existing
/// validation panel over the decision matrix so the user sees "is it correct"
/// and "what will it decide" in one place - replacing the bare validation panel
/// the three-mode chrome used to gate behind a Simulation tab. The matrix takes
/// a resolved rows value, so it skips its body when only validation changes.
struct PolicyCanvasConfidencePanel: View {
  let viewModel: PolicyCanvasViewModel
  let focusIssue: PolicyCanvasIssueFocusAction
  let focusDecision: @MainActor ([String]) -> Void
  let addScenario: @MainActor () -> Void
  let editScenario: @MainActor (String) -> Void
  let deleteScenario: @MainActor (String) -> Void
  let resetScenarios: @MainActor () -> Void
  let loadReplay: @MainActor () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      PolicyCanvasValidationPanel(viewModel: viewModel, focus: focusIssue)
      PolicyCanvasDecisionMatrixView(
        rows: viewModel.decisionMatrixRows,
        isEvaluating: viewModel.isSimulating,
        focusDecision: focusDecision
      )
      PolicyCanvasScenarioInspector(
        rows: viewModel.scenarioRows,
        isEvaluating: viewModel.isSimulating,
        focusDecision: focusDecision,
        addScenario: addScenario,
        editScenario: editScenario,
        deleteScenario: deleteScenario,
        resetScenarios: resetScenarios
      )
      PolicyCanvasReplayInspector(
        rows: viewModel.replayRows,
        summary: viewModel.replaySummary,
        isLoading: viewModel.isReplaying,
        isStale: viewModel.replayIsStale,
        focusDecision: focusDecision,
        loadReplay: loadReplay
      )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasConfidencePanel)
  }
}
