import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Coverage for the Wave 4L motion + reduce-motion contract:
/// - `PolicyCanvasMotion.*` helpers return `nil` under reduce-motion, an
///   animation when reduce-motion is off (so `withAnimation(nil) { ... }`
///   collapses to instant assignment per SwiftUI's documented behavior).
/// - Drop-end through `endNodeDrag` / `endGroupDrag` still lands the node /
///   group at the destination position regardless of the animation gating —
///   the helper governs how the position write reads on screen, not whether
///   it happens.
/// - Selection-mark and zoom-chrome paths flip the underlying view-model
///   field that the `.animation(value:)` modifier in
///   `PolicyCanvasNodeLayer` / `PolicyCanvasZoomControls` keys on.
@Suite("Policy canvas motion + reduce-motion")
@MainActor
struct PolicyCanvasMotionTests {
  // MARK: - PolicyCanvasMotion helper contract

  @Test("spring returns nil under reduce-motion")
  func springReturnsNilUnderReduceMotion() {
    #expect(PolicyCanvasMotion.spring(reducedMotion: true) == nil)
  }

  @Test("spring returns an animation when reduce-motion is off")
  func springReturnsAnimationWhenReduceMotionIsOff() {
    #expect(PolicyCanvasMotion.spring(reducedMotion: false) != nil)
  }

  @Test("zoom transition returns nil under reduce-motion")
  func zoomTransitionReturnsNilUnderReduceMotion() {
    #expect(PolicyCanvasMotion.zoomTransition(reducedMotion: true) == nil)
  }

  @Test("zoom transition returns an animation when reduce-motion is off")
  func zoomTransitionReturnsAnimationWhenReduceMotionIsOff() {
    #expect(PolicyCanvasMotion.zoomTransition(reducedMotion: false) != nil)
  }

  @Test("selection-mark transition returns nil under reduce-motion")
  func selectionMarkReturnsNilUnderReduceMotion() {
    #expect(PolicyCanvasMotion.selectionMark(reducedMotion: true) == nil)
  }

  @Test("selection-mark transition returns an animation when reduce-motion is off")
  func selectionMarkReturnsAnimationWhenReduceMotionIsOff() {
    #expect(PolicyCanvasMotion.selectionMark(reducedMotion: false) != nil)
  }

  @Test("selection-mark hoisted constants pair with reduced-motion bit")
  func selectionMarkHoistedConstantsPairWithReducedMotionBit() {
    #expect(PolicyCanvasMotion.selectionMarkEnabled != nil)
    #expect(PolicyCanvasMotion.selectionMarkDisabled == nil)
    let resolved = PolicyCanvasMotion.selectionMark(reducedMotion: false)
    #expect(resolved == PolicyCanvasMotion.selectionMarkEnabled)
    #expect(PolicyCanvasMotion.selectionMark(reducedMotion: true) == nil)
  }

  // MARK: - Environment seam (Wave 4K consumer contract)

  @Test("policyCanvasReducedMotion defaults to nil outside the canvas")
  func environmentDefaultsToNil() {
    let values = EnvironmentValues()
    #expect(values.policyCanvasReducedMotion == nil)
  }

  @Test("policyCanvasReducedMotion round-trips when written")
  func environmentRoundTripsWhenWritten() {
    var values = EnvironmentValues()
    values.policyCanvasReducedMotion = true
    #expect(values.policyCanvasReducedMotion == true)
    values.policyCanvasReducedMotion = false
    #expect(values.policyCanvasReducedMotion == false)
    values.policyCanvasReducedMotion = nil
    #expect(values.policyCanvasReducedMotion == nil)
  }

  // MARK: - Drop-end behavior under animation gating

  /// `endNodeDrag` writes the final position through `mutate(.moveNode)`. The
  /// node-layer caller wraps that call in `withAnimation(spring(...))`; the
  /// helper returning `nil` under reduce-motion collapses the wrap to a
  /// plain assignment per `withAnimation(nil) { ... }`. Either way the
  /// destination position lands on the snapped grid coordinate. This test
  /// asserts the underlying mutation path stays correct so a future
  /// animation regression cannot mask a position-write regression.
  @Test("end node drag persists snapped destination regardless of motion gating")
  func endNodeDragPersistsSnappedDestinationRegardlessOfMotionGating() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "risk-score"
    let starting = viewModel.node(nodeID)?.position ?? .zero
    let translation = CGSize(width: 48, height: 32)

    viewModel.dragNode(nodeID, translation: translation)
    // The view layer would wrap this in `withAnimation(.spring(...))` when
    // reduce-motion is off, and in `withAnimation(nil)` when reduce-motion
    // is on — both must reach the same end state on the view-model. Direct
    // invocation here covers the post-`withAnimation` body the SwiftUI
    // runtime would invoke.
    viewModel.endNodeDrag(nodeID, translation: translation)

    let landed = viewModel.node(nodeID)?.position ?? .zero
    #expect(landed.x != starting.x || landed.y != starting.y)
    #expect(
      landed.x.truncatingRemainder(dividingBy: PolicyCanvasLayout.gridSize) == 0
    )
    #expect(
      landed.y.truncatingRemainder(dividingBy: PolicyCanvasLayout.gridSize) == 0
    )
    #expect(viewModel.documentDirty)
  }

  /// Group drag end writes new positions for every member node through the
  /// undo funnel; the group frame is rebuilt from those member positions by
  /// `reconcileGroupFrames`. The motion-gating wrap is what the view layer
  /// adds; the underlying contract here is that the member positions move
  /// by the gesture delta regardless of whether the wrap produced a real
  /// animation or `nil`.
  @Test("end group drag moves member nodes regardless of motion gating")
  func endGroupDragMovesMemberNodesRegardlessOfMotionGating() {
    let viewModel = PolicyCanvasViewModel.sample()
    let groupID = "group-intake"
    let memberID = "policy-source"
    let startingPosition = viewModel.node(memberID)?.position ?? .zero
    let translation = CGSize(width: 24, height: 48)

    viewModel.dragGroup(groupID, translation: translation)
    viewModel.endGroupDrag(groupID, translation: translation)

    let landed = viewModel.node(memberID)?.position ?? .zero
    #expect(landed.x != startingPosition.x || landed.y != startingPosition.y)
    #expect(
      landed.x.truncatingRemainder(dividingBy: PolicyCanvasLayout.gridSize) == 0
    )
    #expect(
      landed.y.truncatingRemainder(dividingBy: PolicyCanvasLayout.gridSize) == 0
    )
  }

  // MARK: - Selection-mark gating

  /// The selection-mark transition is applied via `.animation(value:)` on
  /// the stroke overlay inside `PolicyCanvasNodeCard`. The view-model
  /// surfaces `selection` as the @Observable bit the `.animation(value:)`
  /// modifier keys on; toggling selection must flip that field so the
  /// SwiftUI runtime sees a value change to animate through.
  @Test("selecting a node flips the value the selection-mark transition keys on")
  func selectingNodeFlipsSelectionValue() {
    let viewModel = PolicyCanvasViewModel.sample()
    let nodeID = "policy-source"

    #expect(viewModel.selection != .node(nodeID))
    viewModel.select(.node(nodeID))
    #expect(viewModel.selection == .node(nodeID))
    viewModel.select(nil)
    #expect(viewModel.selection == nil)
  }

  @Test("selecting an edge flips the value the selection-mark transition keys on")
  func selectingEdgeFlipsSelectionValue() {
    let viewModel = PolicyCanvasViewModel.sample()
    guard let edgeID = viewModel.edges.first?.id else {
      Issue.record("Sample view model has no edges")
      return
    }

    viewModel.select(.edge(edgeID))
    #expect(viewModel.selectedEdge?.id == edgeID)
    viewModel.select(nil)
    #expect(viewModel.selectedEdge == nil)
  }

  @Test("selecting a group flips the value the selection-mark transition keys on")
  func selectingGroupFlipsSelectionValue() {
    let viewModel = PolicyCanvasViewModel.sample()
    let groupID = "group-intake"

    viewModel.select(.group(groupID))
    #expect(viewModel.selectedGroup?.id == groupID)
    viewModel.select(nil)
    #expect(viewModel.selectedGroup == nil)
  }

  // MARK: - Zoom-chrome animation gating

  /// The chrome zoom buttons wrap their `setZoom` calls in
  /// `withAnimation(.zoomTransition(...))`. The view-model still clamps and
  /// writes the new zoom regardless of whether the wrapper produced a real
  /// animation or `nil`. This test pins the mutation contract so a future
  /// regression that drops the clamp or skips the write would surface here
  /// even before the SwiftUI runtime evaluates the animation.
  @Test("zoom-in chrome action advances zoom under both motion settings")
  func zoomInAdvancesZoom() {
    let viewModel = PolicyCanvasViewModel.sample()
    let initial = viewModel.zoom

    viewModel.zoomIn()

    #expect(viewModel.zoom > initial)
    #expect(viewModel.zoom <= 1.4)
  }

  @Test("zoom-out chrome action retreats zoom under both motion settings")
  func zoomOutRetreatsZoom() {
    let viewModel = PolicyCanvasViewModel.sample()
    let initial = viewModel.zoom

    viewModel.zoomOut()

    #expect(viewModel.zoom < initial)
    #expect(viewModel.zoom >= 0.6)
  }

  @Test("reset-zoom chrome action returns to identity under both motion settings")
  func resetZoomReturnsToIdentity() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setZoom(1.3)
    #expect(viewModel.zoom == 1.3)

    viewModel.resetZoom()

    #expect(viewModel.zoom == 1.0)
  }

  /// Cover the full chrome zoom round-trip so the animation wrap on the view
  /// side has a deterministic underlying transition to animate: start at
  /// 1.0, zoomIn twice, resetZoom — final state must be 1.0.
  @Test("zoom round-trip via chrome buttons returns to identity")
  func zoomRoundTripViaChromeButtonsReturnsToIdentity() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.resetZoom()
    let identity = viewModel.zoom

    viewModel.zoomIn()
    viewModel.zoomIn()
    viewModel.resetZoom()

    #expect(viewModel.zoom == identity)
  }
}
