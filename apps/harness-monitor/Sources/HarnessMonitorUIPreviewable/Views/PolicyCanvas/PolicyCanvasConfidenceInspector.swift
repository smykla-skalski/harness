import HarnessMonitorKit
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasView {
  /// Trailing confidence pane rendered inside the canvas's own HStack (see
  /// `policyCanvasSplitLayout`) instead of a SwiftUI `.inspector`. A native
  /// inspector here promoted a third NavigationSplitView column, which split the
  /// window toolbar and let the detail underlap the translucent sidebar (hiding
  /// the component library). A fixed-width in-layout column keeps full geometry
  /// control and leaves the toolbar and sidebar untouched. The panel fills the
  /// pane height and each list section scrolls within its own share, so the
  /// Replay anchor and every section header stay visible instead of one long
  /// section (a 13-row decisions matrix, or an expanded scenario list) pushing
  /// the others below the fold.
  var policyCanvasConfidencePane: some View {
    HStack(spacing: 0) {
      Rectangle()
        .fill(PolicyCanvasVisualStyle.separator)
        .frame(width: 1)
        .frame(maxHeight: .infinity)

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
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
