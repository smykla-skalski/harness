import SwiftUI

extension PolicyCanvasViewModel {
  func select(_ newSelection: PolicyCanvasSelection?) {
    selection = newSelection
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
  func setZoom(_ nextZoom: CGFloat) {
    zoom = min(1.4, max(0.6, nextZoom))
    viewportDirty = true
  }

  func palettePayload(for kind: PolicyCanvasNodeKind) -> String {
    "policy-canvas-palette|\(kind.rawValue)"
  }

  func portDragPayload(nodeID: String, portID: String) -> String {
    "policy-canvas-port|\(nodeID)|\(portID)"
  }

  func canvasPoint(for viewportPoint: CGPoint) -> CGPoint {
    CGPoint(x: viewportPoint.x / zoom, y: viewportPoint.y / zoom)
  }
}
