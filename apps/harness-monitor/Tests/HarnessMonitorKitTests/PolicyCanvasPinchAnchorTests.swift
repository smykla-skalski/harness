import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Locks the pinch-anchored zoom contract. The viewport's content
/// `.scaleEffect` reads `viewModel.pinchAnchorUnit` so the canvas scales
/// around the point under the user's fingers during a `MagnifyGesture`.
/// Chrome buttons must leave the anchor nil so Cmd-+ / Cmd-= / Cmd-- /
/// Cmd-0 scale from the top-leading origin (preserving prior visual
/// behavior). `clearPinchAnchor()` is the gesture-end / scene-interruption
/// drop point.
@Suite("Policy canvas pinch anchor")
@MainActor
struct PolicyCanvasPinchAnchorTests {
  @Test("default state has no pinch anchor and chrome zoom does not set one")
  func defaultAndChromeZoomHaveNilAnchor() {
    let viewModel = PolicyCanvasViewModel.sample()
    #expect(viewModel.pinchAnchorUnit == nil)
    viewModel.zoomIn()
    #expect(viewModel.pinchAnchorUnit == nil)
    viewModel.zoomOut()
    #expect(viewModel.pinchAnchorUnit == nil)
    viewModel.resetZoom()
    #expect(viewModel.pinchAnchorUnit == nil)
  }

  @Test("setZoom with an anchor stores the anchor for the scaleEffect")
  func setZoomWithAnchorStoresAnchor() {
    let viewModel = PolicyCanvasViewModel.sample()
    let anchor = UnitPoint(x: 0.3, y: 0.7)
    viewModel.setZoom(1.2, anchor: anchor)
    #expect(viewModel.pinchAnchorUnit == anchor)
    #expect(viewModel.zoom == 1.2)
  }

  @Test("clearPinchAnchor drops the anchor so chrome zoom resumes top-leading")
  func clearPinchAnchorDropsAnchor() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setZoom(1.1, anchor: UnitPoint(x: 0.5, y: 0.5))
    #expect(viewModel.pinchAnchorUnit != nil)

    viewModel.clearPinchAnchor()
    #expect(viewModel.pinchAnchorUnit == nil)
  }

  @Test("setZoom with anchor still clamps zoom into [0.1, 1.4]")
  func setZoomWithAnchorClampsRange() {
    let viewModel = PolicyCanvasViewModel.sample()
    let anchor = UnitPoint(x: 0.25, y: 0.75)

    viewModel.setZoom(5.0, anchor: anchor)
    #expect(viewModel.zoom == 1.4)
    #expect(viewModel.pinchAnchorUnit == anchor)

    viewModel.setZoom(0.01, anchor: anchor)
    #expect(viewModel.zoom == PolicyCanvasLayout.minimumZoom)
  }

  @Test("setZoom with a different anchor updates the stored anchor")
  func setZoomReplacesAnchor() {
    let viewModel = PolicyCanvasViewModel.sample()
    let first = UnitPoint(x: 0.1, y: 0.1)
    let second = UnitPoint(x: 0.9, y: 0.9)

    viewModel.setZoom(1.1, anchor: first)
    #expect(viewModel.pinchAnchorUnit == first)
    viewModel.setZoom(1.2, anchor: second)
    #expect(viewModel.pinchAnchorUnit == second)
  }

  @Test("setZoom with nil anchor leaves an existing anchor untouched")
  func nilAnchorIsNonDestructive() {
    let viewModel = PolicyCanvasViewModel.sample()
    let anchor = UnitPoint(x: 0.4, y: 0.6)
    viewModel.setZoom(1.1, anchor: anchor)

    viewModel.setZoom(1.2, anchor: nil)
    // Chrome buttons (zoomIn/zoomOut/resetZoom) currently call
    // clearPinchAnchor explicitly, so the only zero-anchor call site is the
    // bare `setZoom(_:)` overload — which routes through setZoom(_:anchor:)
    // would not be reached with anchor=nil from in-app code. Lock the
    // unsurprising semantics here so future callers can rely on the rule.
    #expect(viewModel.pinchAnchorUnit == anchor)
    #expect(viewModel.zoom == 1.2)
  }
}
