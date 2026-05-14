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

  // `clearTransientGestureState()` lives in PolicyCanvasViewModel+EdgeCreation
  // (post Wave 2D+2F merge consolidation), so re-declaring it here breaks
  // compile. Keep the call site in `clearSelection()` above but route through
  // the unified helper that also clears `pendingEdgePreview`.

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
  func setZoom(_ nextZoom: CGFloat) {
    zoom = min(1.4, max(0.6, nextZoom))
    viewportDirty = true
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
