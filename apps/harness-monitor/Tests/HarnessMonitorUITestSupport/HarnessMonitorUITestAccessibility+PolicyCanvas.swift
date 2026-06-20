extension HarnessMonitorUITestAccessibility {
  static let policyCanvasRoot = "harness.policy-canvas.root"
  static let policyCanvasTopBar = "harness.policy-canvas.top-bar"
  static let policyCanvasLiveStatusBadge = "harness.policy-canvas.live-status"
  static let policyCanvasConfidencePanel = "harness.policy-canvas.confidence"
  static let policyCanvasDecisionMatrix = "harness.policy-canvas.decision-matrix"
  static let policyCanvasViewport = "harness.policy-canvas.viewport"
  static let policyCanvasToolRail = "harness.policy-canvas.tool-rail"
  static let policyCanvasComponentLibrary = "harness.policy-canvas.component-library"
  static let policyCanvasEditButton = "harness.policy-canvas.action.edit"
  static let policyCanvasEditSheet = "harness.policy-canvas.edit-sheet"
  static let policyCanvasEditDoneButton = "harness.policy-canvas.edit-sheet.done"
  static let policyCanvasReformatButton = "harness.policy-canvas.action.reformat"
  static let policyCanvasMakeLiveButton = "harness.policy-canvas.action.make-live"
  static let policyCanvasGoLiveSheet = "harness.policy-canvas.go-live.sheet"
  static let policyCanvasZoomControls = "harness.policy-canvas.zoom"
  static let policyCanvasZoomOutButton = "harness.policy-canvas.zoom.out"
  static let policyCanvasZoomInButton = "harness.policy-canvas.zoom.in"
  static let policyCanvasZoomResetButton = "harness.policy-canvas.zoom.reset"
  static let policyCanvasZoomValue = "harness.policy-canvas.zoom.value"
  static let policyCanvasMinimap = "harness.policy-canvas.minimap"
  static let policyCanvasMinimapViewport = "harness.policy-canvas.minimap.viewport"
  static let policyCanvasInspector = "harness.policy-canvas.inspector"

  static func policyCanvasInspectorField(_ fieldID: String) -> String {
    "harness.policy-canvas.inspector.\(slug(fieldID))"
  }

  static func policyCanvasNode(_ nodeID: String) -> String {
    "harness.policy-canvas.node.\(slug(nodeID))"
  }

  static func policyCanvasGroup(_ groupID: String) -> String {
    "harness.policy-canvas.group.\(slug(groupID))"
  }

  static func policyCanvasPort(_ nodeID: String, _ portID: String) -> String {
    "\(policyCanvasNode(nodeID)).port.\(slug(portID))"
  }

  static func policyCanvasEdge(_ edgeID: String) -> String {
    "harness.policy-canvas.edge.\(slug(edgeID))"
  }

  static func policyCanvasPaletteItem(_ kind: String) -> String {
    "harness.policy-canvas.palette.\(slug(kind))"
  }

  static func policyCanvasDecisionRow(_ actionRaw: String) -> String {
    "harness.policy-canvas.decision-matrix.row.\(slug(actionRaw))"
  }
}
