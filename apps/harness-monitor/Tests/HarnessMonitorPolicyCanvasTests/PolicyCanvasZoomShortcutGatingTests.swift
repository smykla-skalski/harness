import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas zoom shortcut dispatcher")
@MainActor
struct PolicyCanvasZoomShortcutGatingTests {
  @Test("dispatcher perform methods are no-ops until closures are bound")
  func dispatcherIsInertWhenUnbound() {
    let dispatcher = PolicyCanvasZoomFocusDispatcher()
    dispatcher.performZoomIn()
    dispatcher.performZoomOut()
    dispatcher.performResetZoom()
  }

  @Test("zoom in dispatches to the bound closure")
  func zoomInDispatches() {
    let dispatcher = PolicyCanvasZoomFocusDispatcher()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setZoom(1)
    dispatcher.zoomIn = { viewModel.zoomIn() }

    dispatcher.performZoomIn()
    #expect(viewModel.zoom > 1)
  }

  @Test("zoom out dispatches to the bound closure")
  func zoomOutDispatches() {
    let dispatcher = PolicyCanvasZoomFocusDispatcher()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setZoom(1)
    dispatcher.zoomOut = { viewModel.zoomOut() }

    dispatcher.performZoomOut()
    #expect(viewModel.zoom < 1)
  }

  @Test("reset zoom dispatches to the bound closure")
  func resetZoomDispatches() {
    let dispatcher = PolicyCanvasZoomFocusDispatcher()
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setZoom(1.3)
    dispatcher.resetZoom = { viewModel.resetZoom() }

    dispatcher.performResetZoom()
    #expect(viewModel.zoom == 1)
  }

  @Test("PolicyCanvasZoomFocus equality is identity-based on the dispatcher")
  func zoomFocusEqualityIsIdentityBased() {
    let dispatcher = PolicyCanvasZoomFocusDispatcher()
    let focusA = PolicyCanvasZoomFocus(dispatcher: dispatcher)
    let focusB = PolicyCanvasZoomFocus(dispatcher: dispatcher)
    let otherDispatcher = PolicyCanvasZoomFocusDispatcher()
    let focusC = PolicyCanvasZoomFocus(dispatcher: otherDispatcher)

    #expect(focusA == focusB)
    #expect(focusA != focusC)
  }
}
