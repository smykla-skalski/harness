import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas command-scroll zoom")
@MainActor
struct PolicyCanvasCommandScrollTests {
  @Test("delta requires the command modifier")
  func commandScrollEventRequiresCommandModifier() {
    let unmodifiedDelta = policyCanvasCommandScrollDeltaY(
      isCommandModified: false,
      oldOffset: CGPoint(x: 40, y: 120),
      newOffset: CGPoint(x: 40, y: 112)
    )
    #expect(unmodifiedDelta == nil)

    let verticalDelta = policyCanvasCommandScrollDeltaY(
      isCommandModified: true,
      oldOffset: CGPoint(x: 40, y: 120),
      newOffset: CGPoint(x: 40, y: 112)
    )
    #expect(verticalDelta == 8)

    let horizontalDelta = policyCanvasCommandScrollDeltaY(
      isCommandModified: true,
      oldOffset: CGPoint(x: 40, y: 120),
      newOffset: CGPoint(x: 44, y: 120)
    )
    #expect(horizontalDelta == -4)

    let noScroll = policyCanvasCommandScrollDeltaY(
      isCommandModified: true,
      oldOffset: CGPoint(x: 40, y: 120),
      newOffset: CGPoint(x: 40, y: 120)
    )
    #expect(noScroll == nil)
  }

  @Test("zoom changes and recomputed scroll keeps the pointer anchored")
  func commandScrollZoomsAroundPointer() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setZoom(1)

    let viewportPoint = CGPoint(x: 340, y: 220)
    let viewportSize = CGSize(width: 1_100, height: 820)
    let oldScrollOffset = CGPoint(x: 200, y: 160)
    let canvasPoint = CGPoint(
      x: (oldScrollOffset.x + viewportPoint.x) / viewModel.zoom,
      y: (oldScrollOffset.y + viewportPoint.y) / viewModel.zoom
    )

    #expect(viewModel.zoomByCommandScroll(deltaY: 30))
    #expect(viewModel.zoom > 1)

    let nextScroll = viewModel.viewportScrollPoint(
      keepingCanvasPoint: canvasPoint,
      atViewportPoint: viewportPoint,
      viewportSize: viewportSize
    )

    let recomputedCursorOverContent = CGPoint(
      x: (nextScroll.x + viewportPoint.x) / viewModel.zoom,
      y: (nextScroll.y + viewportPoint.y) / viewModel.zoom
    )

    #expect(abs(recomputedCursorOverContent.x - canvasPoint.x) < 0.001)
    #expect(abs(recomputedCursorOverContent.y - canvasPoint.y) < 0.001)
  }

  @Test("delta is clamped so zoom stays in bounds")
  func commandScrollDeltaIsClampedToZoomBounds() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setZoom(1)

    for _ in 0..<200 {
      _ = viewModel.zoomByCommandScroll(deltaY: 10_000)
    }
    #expect(viewModel.zoom <= 1.4)

    viewModel.setZoom(1)
    for _ in 0..<200 {
      _ = viewModel.zoomByCommandScroll(deltaY: -10_000)
    }
    #expect(viewModel.zoom >= 0.6)
  }

  @Test("target zoom helper mirrors view-model command-scroll semantics")
  func targetZoomHelperMatchesViewModelMutation() {
    let delta: CGFloat = 30
    let currentZoom: CGFloat = 1
    let targetZoom = policyCanvasCommandScrollTargetZoom(
      currentZoom: currentZoom,
      deltaY: delta
    )

    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setZoom(currentZoom)
    #expect(viewModel.zoomByCommandScroll(deltaY: delta))

    #expect(targetZoom == viewModel.zoom)
  }

  @Test("target zoom helper returns nil when zoom stays clamped")
  func targetZoomHelperReturnsNilAtClamp() {
    #expect(policyCanvasCommandScrollTargetZoom(currentZoom: 1, deltaY: 0) == nil)
    #expect(policyCanvasCommandScrollTargetZoom(currentZoom: 1.4, deltaY: 80) == nil)
    #expect(policyCanvasCommandScrollTargetZoom(currentZoom: 0.6, deltaY: -80) == nil)
  }

  @Test("viewport defers command-scroll correction out of scroll geometry callback")
  func viewportDefersCommandScrollCorrection() throws {
    let source =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")
    let coordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(source.contains("commandScrollCoordinator.consumePendingRestoration()"))
    #expect(source.contains("commandScrollCoordinator.schedule("))
    #expect(source.contains("PolicyCanvasViewportScrollApplicator("))
    #expect(source.contains("requestViewportScroll(to: request.scrollPoint)"))
    #expect(source.contains("await Task.yield()"))
    #expect(!source.contains(".scrollPosition($scrollPosition)"))
    #expect(!source.contains("scrollProxy.scrollTo("))
    #expect(!source.contains("ScrollViewReader {"))
    #expect(coordinatorSource.contains("contentView.scroll(to:"))
    #expect(coordinatorSource.contains("commandScrollCoordinator.armPendingRestoration()") == false)
  }

  @Test("viewport centering is consumed only after the scroll applicator fulfills it")
  func viewportCenteringConsumesOnApplicatorFulfillment() throws {
    let source =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")

    #expect(source.contains("viewModel.hasPendingViewportCenteringRequest"))
    #expect(!source.contains("guard viewModel.consumeViewportCenteringRequest()"))
    #expect(source.contains("if request.consumesViewportCenteringRequest {"))
    #expect(source.contains("_ = viewModel.consumeViewportCenteringRequest()"))
  }

  @Test("zero-delta short-circuits and reports no change")
  func zeroDeltaIsRejected() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setZoom(1)
    #expect(viewModel.zoomByCommandScroll(deltaY: 0) == false)
    #expect(viewModel.zoom == 1)
  }

  private func previewableSourceFile(named path: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent(path)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
