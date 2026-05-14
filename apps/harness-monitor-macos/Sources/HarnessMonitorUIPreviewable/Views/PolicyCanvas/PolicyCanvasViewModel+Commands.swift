import SwiftUI

extension PolicyCanvasViewModel {
  func select(_ newSelection: PolicyCanvasSelection?) {
    selection = newSelection
  }

  /// Drops the current selection and any in-flight gesture highlights. Wired
  /// to the canvas-wide Escape shortcut so a misclicked drag or a stuck
  /// drop-zone tint never leaves the canvas in a quiet "still hovering"
  /// state. No document-side mutation, so `documentDirty` is untouched.
  func clearSelection() {
    selection = nil
    clearTransientGestureState()
  }

  /// Clears transient gesture state without mutating the persisted graph.
  /// `highlightedInput` is fed by `setInputTargeted(_:nodeID:portID:)` while
  /// a port drag is over a drop target; `highlightedGroupID` is set by node
  /// and group drags. Both are cleared on drag-end normally, but rejected
  /// gestures (Escape, daemon-side reject, foreign delete) can leave them
  /// stale — call this method on those paths to keep the canvas quiet.
  func clearTransientGestureState() {
    highlightedInput = nil
    highlightedGroupID = nil
    clearPendingEdge()
  }

  func save() {
    notifyStatus("Draft saved")
  }

  func simulate() {
    selectedTab = .simulation
    notifyStatus("Simulation queued")
  }

  func promote() {
    selectedTab = .promotion
    notifyStatus("Promotion requested")
  }

  func zoomIn() {
    setZoom(zoom + 0.1)
  }

  func zoomOut() {
    setZoom(zoom - 0.1)
  }

  func resetZoom() {
    setZoom(1)
  }

  /// Updates the canvas zoom and marks the viewport (not the document) dirty.
  /// Viewport state is window-scoped layout, not part of the saved pipeline.
  @discardableResult
  func setZoom(_ nextZoom: CGFloat) -> Bool {
    let clampedZoom = min(1.4, max(0.6, nextZoom))
    guard clampedZoom != zoom else {
      return false
    }
    zoom = clampedZoom
    viewportDirty = true
    return true
  }

  @discardableResult
  func zoomByCommandScroll(deltaY: CGFloat) -> Bool {
    guard abs(deltaY) >= 0.1 else {
      return false
    }
    let boundedDelta = min(80, max(-80, deltaY))
    let zoomStep = 1 + (boundedDelta * 0.003)
    return setZoom(zoom * max(0.76, min(1.24, zoomStep)))
  }

  func palettePayload(for kind: PolicyCanvasNodeKind) -> String {
    "policy-canvas-palette|\(kind.rawValue)"
  }

  func portDragPayload(
    nodeID: String,
    portID: String,
    side: PolicyCanvasPortSide? = nil
  ) -> String {
    if let side {
      return "policy-canvas-port|\(nodeID)|\(portID)|\(side.rawValue)"
    }
    return "policy-canvas-port|\(nodeID)|\(portID)"
  }

  func canvasPoint(for viewportPoint: CGPoint) -> CGPoint {
    CGPoint(x: viewportPoint.x / zoom, y: viewportPoint.y / zoom)
  }

  func requestViewportCentering() {
    viewportScrollPoint = nil
    viewportCenteringGeneration += 1
  }

  func consumeViewportCenteringRequest() -> Bool {
    guard centeredViewportGeneration != viewportCenteringGeneration else {
      return false
    }
    centeredViewportGeneration = viewportCenteringGeneration
    return true
  }
}
