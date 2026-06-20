import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasView {
  var policyCanvasConfidenceInspector: some View {
    ScrollView {
      PolicyCanvasConfidencePanel(
        viewModel: viewModel,
        focusIssue: focusPolicyCanvasIssue,
        focusDecision: focusPolicyCanvasDecision,
        addScenario: addScenario,
        editScenario: { id in
          editScenario(id: id)
        },
        deleteScenario: { id in
          deleteScenario(id: id)
        },
        resetScenarios: resetScenarios,
        loadReplay: loadReplay
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(PolicyCanvasVisualStyle.panelBackground)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.policyCanvasConfidencePanel)
    .inspectorColumnWidth(min: 300, ideal: 380, max: 520)
  }

  @MainActor
  func togglePolicyCanvasInspector() {
    policyCanvasInspectorVisible.toggle()
  }

  @MainActor
  func focusPolicyCanvasIssue(_ resolved: PolicyCanvasResolvedIssue) {
    viewModel.focusIssue(resolved)
    if let selection = resolved.focusSelection {
      selectionFocusRequestID &+= 1
      selectionFocusRequest = PolicyCanvasViewportSelectionFocusRequest(
        id: selectionFocusRequestID,
        selection: selection
      )
    }
  }

  @MainActor
  func focusPolicyCanvasDecision(_ visitedNodeIds: [String]) {
    guard let terminal = visitedNodeIds.last else {
      return
    }
    viewModel.select(.node(terminal))
    selectionFocusRequestID &+= 1
    selectionFocusRequest = PolicyCanvasViewportSelectionFocusRequest(
      id: selectionFocusRequestID,
      selection: .node(terminal)
    )
  }
}
