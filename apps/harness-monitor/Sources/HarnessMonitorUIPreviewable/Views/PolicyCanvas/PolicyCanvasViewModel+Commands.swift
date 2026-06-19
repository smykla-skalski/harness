import Foundation
import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

extension PolicyCanvasViewModel {
  static func sanitizedZoom(_ candidate: CGFloat, fallback: CGFloat) -> CGFloat {
    guard candidate.isFinite else {
      return fallback
    }
    return min(PolicyCanvasLayout.maximumZoom, max(PolicyCanvasLayout.minimumZoom, candidate))
  }

  /// Single-click selection: replaces the primary selection and drops any
  /// secondary picks. Shift-click goes through `extendSelection(_:)` instead
  /// to layer onto the existing set.
  func select(_ newSelection: PolicyCanvasSelection?) {
    selection = newSelection
    secondarySelections = []
    selectedBranchDaemonEdgeID = nil
  }

  /// Drops the current selection and any in-flight gesture highlights. Wired
  /// to the canvas-wide Escape shortcut so a misclicked drag or a stuck
  /// drop-zone tint never leaves the canvas in a quiet "still hovering"
  /// state. No document-side mutation, so `documentDirty` is untouched.
  func clearSelection() {
    selection = nil
    secondarySelections = []
    selectedBranchDaemonEdgeID = nil
    clearTransientGestureState()
  }

  /// Drop every piece of in-flight gesture state in one call: the rubber-band
  /// edge preview (via `clearPendingEdge()`), the highlighted input port
  /// stroke, and the highlighted drop-target group. Use this from interruption
  /// surfaces (scenePhase transitions, Escape keypress, document republish)
  /// where the canvas needs to return to a resting state regardless of which
  /// gesture was mid-flight.
  ///
  /// Routes the pending-edge clear through `clearPendingEdge()` so the
  /// rubber-band presence-bit (`hasPendingEdge`) stays in sync — Wave 2F is
  /// the only writer of that bit, and reaching past its single setter would
  /// strand views that subscribe to the bit instead of the payload.
  ///
  /// Idempotent — every write is to optional storage that may already be nil.
  func clearTransientGestureState() {
    highlightedInput = nil
    highlightedGroupID = nil
    marqueeSelection = nil
    clearPendingEdge()
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
  ///
  /// Equality damping is load-bearing on the pinch path: `MagnifyGesture`
  /// writes per gesture tick (~60-120Hz), and `@Observable` does not diff
  /// before notifying observers. A pinch pinned at the clamp (0.1 or 2.0)
  /// would otherwise fire two notifications per frame for the duration of
  /// the pinch — once for `zoom`, once for `viewportDirty`. Guarding both
  /// writes against their current values drops the bottom-of-range and
  /// top-of-range storms entirely.
  func setZoom(_ nextZoom: CGFloat) {
    let clamped = Self.sanitizedZoom(nextZoom, fallback: zoom)
    guard clamped != zoom else {
      return
    }
    zoom = clamped
    if !viewportDirty {
      viewportDirty = true
    }
  }

  /// Pinch-anchored zoom. Captures the gesture's focal point as a unit-space
  /// anchor (x, y in [0, 1] over the content size) so the rendering scale
  /// effect can apply the zoom around the point under the user's fingers.
  /// Falls back to the plain `setZoom(_:)` when the anchor is nil so chrome
  /// buttons (Cmd-+ / Cmd-= / Cmd--) keep their existing top-leading anchor.
  ///
  /// The anchor write is funneled through this entry point so the pinch
  /// gesture handler can update both the scale value and the anchor in a
  /// single observation-coherent turn.
  func setZoom(_ nextZoom: CGFloat, anchor: UnitPoint?) {
    if let anchor, anchor != pinchAnchorUnit {
      pinchAnchorUnit = anchor
    }
    setZoom(nextZoom)
  }

  /// Drops the pinch anchor so subsequent chrome-button zooms render from the
  /// canvas top-leading origin. Called from the magnify gesture's `.onEnded`
  /// and from scene-phase interruption surfaces so a window-deactivation
  /// mid-pinch does not strand a stale anchor.
  func clearPinchAnchor() {
    if pinchAnchorUnit != nil {
      pinchAnchorUnit = nil
    }
  }

  func palettePayload(for kind: PolicyCanvasNodeKind) -> String {
    "policy-canvas-palette|\(kind.rawValue)"
  }

  func palettePayload(for item: PolicyCanvasAutomationPaletteItem) -> String {
    "policy-canvas-automation-palette|\(item.rawValue)"
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

  func canvasPoint(
    for viewportPoint: CGPoint,
    scaledCanvasOffset: CGPoint = .zero
  ) -> CGPoint {
    policyCanvasCanvasPoint(
      presentedPoint: viewportPoint,
      zoom: zoom,
      scaledCanvasOffset: scaledCanvasOffset
    )
  }

  func requestViewportCentering(
    _ behavior: PolicyCanvasViewportCenteringBehavior = .document
  ) {
    viewportCenteringBehavior = behavior
    viewportCenteringGeneration += 1
  }

  func requestRouteComputation() {
    routeComputationRequestGeneration &+= 1
  }

  var hasPendingViewportCenteringRequest: Bool {
    centeredViewportGeneration != viewportCenteringGeneration
  }

  func consumeViewportCenteringRequest() -> Bool {
    consumeViewportCenteringRequest(generation: viewportCenteringGeneration)
  }

  func consumeViewportCenteringRequest(generation: UInt64) -> Bool {
    guard hasPendingViewportCenteringRequest else {
      return false
    }
    guard generation == viewportCenteringGeneration else {
      return false
    }
    centeredViewportGeneration = generation
    return true
  }
}
