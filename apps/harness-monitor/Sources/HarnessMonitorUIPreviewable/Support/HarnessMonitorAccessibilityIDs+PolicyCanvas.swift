import SwiftUI

extension HarnessMonitorAccessibility {
  public static let policyCanvasRoot = "harness.policy-canvas.root"
  public static let policyCanvasTopBar = "harness.policy-canvas.top-bar"
  public static let policyCanvasViewport = "harness.policy-canvas.viewport"
  public static let policyCanvasTabs = "harness.policy-canvas.tabs"
  public static let policyCanvasToolRail = "harness.policy-canvas.tool-rail"
  public static let policyCanvasComponentLibrary = "harness.policy-canvas.component-library"
  public static let policyCanvasEditButton = "harness.policy-canvas.action.edit"
  public static let policyCanvasEditSheet = "harness.policy-canvas.edit-sheet"
  public static let policyCanvasEditDoneButton = "harness.policy-canvas.edit-sheet.done"
  public static let policyCanvasReformatButton = "harness.policy-canvas.action.reformat"
  public static let policyCanvasSaveButton = "harness.policy-canvas.action.save"
  public static let policyCanvasSimulateButton = "harness.policy-canvas.action.simulate"
  public static let policyCanvasPromoteButton = "harness.policy-canvas.action.promote"
  public static let policyCanvasReloadButton = "harness.policy-canvas.action.reload"
  public static let policyCanvasSimulationToggle = "harness.policy-canvas.action.simulation-overlay"
  public static let policyCanvasZoomControls = "harness.policy-canvas.zoom"
  public static let policyCanvasZoomOutButton = "harness.policy-canvas.zoom.out"
  public static let policyCanvasZoomInButton = "harness.policy-canvas.zoom.in"
  public static let policyCanvasZoomResetButton = "harness.policy-canvas.zoom.reset"
  public static let policyCanvasZoomValue = "harness.policy-canvas.zoom.value"
  public static let policyCanvasMinimap = "harness.policy-canvas.minimap"
  public static let policyCanvasMinimapViewport = "harness.policy-canvas.minimap.viewport"
  public static let policyCanvasEdgeLegend = "harness.policy-canvas.edge-legend"
  public static let policyCanvasEdgeLegendToggle = "harness.policy-canvas.edge-legend.toggle"
  public static let policyCanvasInspector = "harness.policy-canvas.inspector"
  public static let policyCanvasValidationPanel = "harness.policy-canvas.validation"
  public static let policyCanvasValidationToggle = "harness.policy-canvas.validation.toggle"
  public static let policyCanvasEmptyState = "harness.policy-canvas.empty-state"
  public static let policyCanvasSearchPalette = "harness.policy-canvas.search.palette"
  public static let policyCanvasSearchField = "harness.policy-canvas.search.field"
  public static let policyCanvasSearchDismissButton = "harness.policy-canvas.search.dismiss"
  public static let policyCanvasSearchEmptyHint = "harness.policy-canvas.search.empty"
  public static let policyCanvasSearchNoMatch = "harness.policy-canvas.search.no-match"
  public static let policyCanvasSearchLiveRegion = "harness.policy-canvas.search.live-region"
  public static let policyCanvasWorkflowStatusStack = "harness.policy-canvas.workflow-status"

  public static func policyCanvasSearchResult(_ hitID: String) -> String {
    "harness.policy-canvas.search.result.\(slug(hitID))"
  }

  public static func policyCanvasInspectorField(_ fieldID: String) -> String {
    "harness.policy-canvas.inspector.\(slug(fieldID))"
  }

  public static func policyCanvasValidationRow(_ issueID: String) -> String {
    "harness.policy-canvas.validation.row.\(slug(issueID))"
  }

  public static func policyCanvasValidationFocusButton(_ issueID: String) -> String {
    "harness.policy-canvas.validation.focus.\(slug(issueID))"
  }

  public static func policyCanvasNode(_ nodeID: String) -> String {
    "harness.policy-canvas.node.\(slug(nodeID))"
  }

  public static func policyCanvasGroup(_ groupID: String) -> String {
    "harness.policy-canvas.group.\(slug(groupID))"
  }

  public static func policyCanvasPort(_ nodeID: String, _ portID: String) -> String {
    "\(policyCanvasNode(nodeID)).port.\(slug(portID))"
  }

  public static func policyCanvasEdge(_ edgeID: String) -> String {
    "harness.policy-canvas.edge.\(slug(edgeID))"
  }

  public static func policyCanvasPaletteItem(_ kind: String) -> String {
    "harness.policy-canvas.palette.\(slug(kind))"
  }

  public static func policyCanvasSimulationBadge(_ nodeID: String) -> String {
    "harness.policy-canvas.simulation-badge.\(slug(nodeID))"
  }

  public static let voiceInputPopover = "harness.voice-input.popover"
  public static let voiceInputTranscript = "harness.voice-input.transcript"
  public static let voiceInputInsertButton = "harness.voice-input.insert"
  public static let voiceInputStopButton = "harness.voice-input.stop"
  public static let voiceInputRemoteURLField = "harness.voice-input.remote-url"
  public static let voiceInputFailureOverlay = "harness.voice-input.failure"
  public static let voiceInputFailureMessage = "harness.voice-input.failure.message"
  public static let voiceInputFailureInstructions = "harness.voice-input.failure.instructions"
  public static let voiceInputFailureRetryButton = "harness.voice-input.failure.retry"
  public static let voiceInputFailureCloseButton = "harness.voice-input.failure.close"
}
