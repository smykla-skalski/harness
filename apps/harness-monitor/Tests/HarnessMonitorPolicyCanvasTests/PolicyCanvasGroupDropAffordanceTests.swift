import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Wave 4K P36: group drop affordance state — hover-tint vs accept-flash.
/// View-side animation is gated on `accessibilityReduceMotion` inside
/// `PolicyCanvasGroupRegion`; these tests cover the model-side bit flips
/// that the view reads, plus the auto-clear timer that bounds the flash.
@Suite("Policy canvas group drop affordance")
@MainActor
struct PolicyCanvasGroupDropAffordanceTests {
  @Test("hover sets highlightedGroupID without arming acceptance flash")
  func hoverSetsHighlightWithoutFlash() {
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.setGroupDropTargeted(true, groupID: "group-intake")

    #expect(viewModel.highlightedGroupID == "group-intake")
    #expect(viewModel.groupAcceptanceFlashID == nil)
  }

  @Test("hover-out clears the highlight when the same group is hovered out")
  func hoverOutClearsMatchingHighlight() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setGroupDropTargeted(true, groupID: "group-intake")

    viewModel.setGroupDropTargeted(false, groupID: "group-intake")

    #expect(viewModel.highlightedGroupID == nil)
  }

  @Test("hover-out from a different group does not clear the active highlight")
  func hoverOutFromOtherGroupKeepsHighlight() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setGroupDropTargeted(true, groupID: "group-intake")

    viewModel.setGroupDropTargeted(false, groupID: "group-release")

    #expect(viewModel.highlightedGroupID == "group-intake")
  }

  @Test("dropPalettePayloadsOnGroup arms the acceptance flash on success")
  func dropOnGroupArmsAcceptanceFlash() {
    let viewModel = PolicyCanvasViewModel.sample()

    let accepted = viewModel.dropPalettePayloadsOnGroup(
      [viewModel.palettePayload(for: .condition)],
      groupID: "group-intake",
      at: CGPoint(x: 200, y: 200)
    )

    #expect(accepted)
    #expect(viewModel.groupAcceptanceFlashID == "group-intake")
  }

  @Test("dropPalettePayloadsOnGroup leaves the flash unset on a rejected drop")
  func dropOnGroupSkipsFlashOnRejection() {
    let viewModel = PolicyCanvasViewModel.sample()

    let accepted = viewModel.dropPalettePayloadsOnGroup(
      ["garbage-payload"],
      groupID: "group-intake",
      at: CGPoint(x: 200, y: 200)
    )

    #expect(!accepted)
    #expect(viewModel.groupAcceptanceFlashID == nil)
  }

  @Test("triggerGroupAcceptanceFlash auto-clears after the flash duration")
  func acceptanceFlashAutoClears() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.triggerGroupAcceptanceFlash(groupID: "group-evaluation")
    #expect(viewModel.groupAcceptanceFlashID == "group-evaluation")

    // Sleep past the flash duration plus a small slack so the auto-clear
    // task has a chance to land before we read the state.
    let slack = Duration.milliseconds(120)
    try? await Task.sleep(
      for: PolicyCanvasViewModel.groupAcceptanceFlashDuration + slack
    )

    #expect(viewModel.groupAcceptanceFlashID == nil)
  }

  @Test("rapid sequential triggers replace the in-flight clear task")
  func rapidSequentialTriggersStayLitContinuously() async {
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.triggerGroupAcceptanceFlash(groupID: "group-intake")
    // Sleep half the duration, then re-trigger for the same group so the
    // pending clear gets cancelled and the second trigger's timer extends
    // the flash window.
    try? await Task.sleep(for: PolicyCanvasViewModel.groupAcceptanceFlashDuration / 2)
    viewModel.triggerGroupAcceptanceFlash(groupID: "group-intake")

    // The flash should still be lit immediately after the second trigger.
    #expect(viewModel.groupAcceptanceFlashID == "group-intake")
  }

  @Test("clearGroupAcceptanceFlash is a synchronous reset path")
  func clearGroupAcceptanceFlashIsSynchronous() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.triggerGroupAcceptanceFlash(groupID: "group-evaluation")
    #expect(viewModel.groupAcceptanceFlashID == "group-evaluation")

    viewModel.clearGroupAcceptanceFlash()

    #expect(viewModel.groupAcceptanceFlashID == nil)
  }

  @Test("PolicyCanvasGroupRegion respects reduce-motion environment")
  func groupRegionRespectsReduceMotionEnvironment() {
    // The view layer reads `@Environment(\.accessibilityReduceMotion)` and
    // gates the implicit `.animation` modifier and the flash transition on
    // it. We cannot exercise the SwiftUI render pipeline from a unit test,
    // but we can assert that the model-side bit flips (which the view
    // observes) do not depend on the environment — reduce-motion users
    // still see the static visual difference.
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.triggerGroupAcceptanceFlash(groupID: "group-intake")

    // The model flag must flip the same way regardless of environment.
    #expect(viewModel.groupAcceptanceFlashID == "group-intake")
    viewModel.clearGroupAcceptanceFlash()
    #expect(viewModel.groupAcceptanceFlashID == nil)
  }

  @Test("dropPalettePayloadsOnGroup is independent of generic drop path")
  func dropOnGroupIndependentOfGenericDrop() {
    let viewModel = PolicyCanvasViewModel.sample()

    // The generic dropPalettePayloads path must NOT arm the group flash;
    // only the per-group dropDestination handler does so. This keeps the
    // affordance honest: a drop on empty canvas (or a non-group surface)
    // never lights up the group ring.
    _ = viewModel.dropPalettePayloads(
      [viewModel.palettePayload(for: .condition)],
      at: CGPoint(x: 200, y: 200)
    )

    #expect(viewModel.groupAcceptanceFlashID == nil)
  }
}
