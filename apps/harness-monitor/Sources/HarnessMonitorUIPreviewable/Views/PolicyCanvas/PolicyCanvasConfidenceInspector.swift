import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasView {
  /// Trailing confidence pane rendered inside the canvas's own HStack (see
  /// `policyCanvasSplitLayout`) instead of a SwiftUI `.inspector`. A native
  /// inspector here promoted a third NavigationSplitView column, which split the
  /// window toolbar and let the detail underlap the translucent sidebar (hiding
  /// the component library). A fixed-width in-layout column keeps full geometry
  /// control and leaves the toolbar and sidebar untouched. A single ScrollView
  /// owns the whole panel so the decision list, scenarios, and replay scroll
  /// together rather than each clipping behind its own fixed height.
  var policyCanvasConfidencePane: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(width: 1)
        .frame(maxHeight: .infinity)

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
    }
    .frame(width: 380)
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
