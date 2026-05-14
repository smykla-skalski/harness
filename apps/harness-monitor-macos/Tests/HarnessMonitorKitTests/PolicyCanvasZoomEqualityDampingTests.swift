import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Locks the equality damping contract on `setZoom`. `MagnifyGesture`
/// writes per tick (~60-120Hz), and `@Observable` does not diff before
/// notifying observers. The guard against `clamped == zoom` and the
/// one-shot `viewportDirty` write together drop the notification storm
/// when a pinch sits pinned at the clamp range.
@Suite("Policy canvas zoom equality damping")
@MainActor
struct PolicyCanvasZoomEqualityDampingTests {
  @Test("setZoom does nothing when called with the current zoom value")
  func sameValueIsNoop() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.viewportDirty = false
    let originalZoom = viewModel.zoom

    viewModel.setZoom(originalZoom)
    #expect(viewModel.zoom == originalZoom)
    #expect(viewModel.viewportDirty == false)
  }

  @Test("setZoom does nothing on repeated clamp at the upper bound")
  func repeatedUpperClampIsNoopAfterFirstWrite() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setZoom(2.0)
    #expect(viewModel.zoom == 1.4)
    viewModel.viewportDirty = false

    // Subsequent over-the-top writes flow through the clamp to 1.4, which
    // already matches `zoom`, so the equality guard short-circuits and
    // viewportDirty stays clean. A naive `zoom = clamped; viewportDirty =
    // true` would fire on every call.
    for _ in 0..<10 {
      viewModel.setZoom(3.5)
    }
    #expect(viewModel.zoom == 1.4)
    #expect(viewModel.viewportDirty == false)
  }

  @Test("setZoom does nothing on repeated clamp at the lower bound")
  func repeatedLowerClampIsNoopAfterFirstWrite() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setZoom(0.01)
    #expect(viewModel.zoom == 0.6)
    viewModel.viewportDirty = false

    for _ in 0..<10 {
      viewModel.setZoom(-1.0)
    }
    #expect(viewModel.zoom == 0.6)
    #expect(viewModel.viewportDirty == false)
  }

  @Test("setZoom writes and flips viewportDirty on a genuine change")
  func genuineChangeStillFires() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.viewportDirty = false
    let originalZoom = viewModel.zoom

    viewModel.setZoom(originalZoom + 0.2)
    #expect(viewModel.zoom != originalZoom)
    #expect(viewModel.viewportDirty == true)
  }

  @Test("viewportDirty stays true on a second genuine change without flicker")
  func consecutiveGenuineChangesKeepViewportDirty() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.viewportDirty = false

    viewModel.setZoom(0.8)
    #expect(viewModel.viewportDirty == true)
    viewModel.setZoom(1.0)
    #expect(viewModel.viewportDirty == true)
  }
}
