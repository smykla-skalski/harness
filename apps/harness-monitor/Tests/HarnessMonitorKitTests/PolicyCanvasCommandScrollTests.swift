import AppKit
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

  @Test("viewport handles command-scroll from native scroll-wheel events")
  func viewportHandlesCommandScrollFromNativeEvents() throws {
    let source =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")
    let coordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(source.contains("commandScrollCoordinator.schedule("))
    #expect(source.contains("PolicyCanvasViewportScrollApplicator("))
    #expect(source.contains("handleCommandScrollEvent("))
    #expect(!source.contains(".onScrollGeometryChange("))
    #expect(source.contains("requestViewportScroll(to: request.scrollPoint)"))
    #expect(source.contains("await Task.yield()"))
    #expect(!source.contains(".scrollPosition($scrollPosition)"))
    #expect(!source.contains("scrollProxy.scrollTo("))
    #expect(!source.contains("ScrollViewReader {"))
    #expect(source.contains(".task(id: selectionFocusRequest?.id)"))
    #expect(source.contains("let selectionScrollPoint ="))
    #expect(source.contains(".frame(width: 0, height: 0)"))
    #expect(source.contains("isActive: sceneFocusEnabled"))
    #expect(coordinatorSource.contains("contentView.scroll(to:"))
    #expect(coordinatorSource.contains("addLocalMonitorForEvents(matching: [.scrollWheel])"))
    #expect(coordinatorSource.contains("guard isActive else"))
    #expect(coordinatorSource.contains("policyCanvasCommandScrollDeltaY(event: event)"))
    #expect(coordinatorSource.contains("scrollView.convert(locationInWindow, from: nil)"))
    #expect(coordinatorSource.contains("usesPredominantAxisScrolling = false"))
    #expect(coordinatorSource.contains("configureScrollViewIfAvailable(from: self)"))
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

  @Test("viewport keeps retrying a pending scroll request until the scroll view is ready")
  func viewportScrollApplicatorRetriesPendingRequests() throws {
    let coordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(coordinatorSource.contains("enum ApplyRequestResult"))
    #expect(coordinatorSource.contains("return .needsRetry"))
    #expect(coordinatorSource.contains("scheduleRetryIfNeeded()"))
    #expect(coordinatorSource.contains("maxRetryAttempts = 24"))
  }

  @MainActor
  @Test("viewport scroll coordinator recenters after the canvas grows and preserves free diagonal scrolling")
  func viewportScrollCoordinatorRecentersAfterLateLayout() {
    let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let rootView = NSView(frame: frame)
    let scrollView = NSScrollView(frame: frame)
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = true

    let documentView = PolicyCanvasFlippedDocumentView(
      frame: CGRect(x: 0, y: 0, width: 320, height: 240)
    )
    scrollView.documentView = documentView
    rootView.addSubview(scrollView)

    let applicatorView = PolicyCanvasViewportScrollApplicatorView(frame: documentView.bounds)
    applicatorView.autoresizingMask = [.width, .height]
    let coordinator = PolicyCanvasViewportScrollApplicator.Coordinator()
    applicatorView.coordinator = coordinator
    documentView.addSubview(applicatorView)

    let window = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    window.contentView = rootView
    window.layoutIfNeeded()
    rootView.layoutSubtreeIfNeeded()

    let request = PolicyCanvasViewportScrollRequest(
      id: 1,
      point: CGPoint(x: 900, y: 700),
      consumesViewportCenteringRequest: false
    )
    var fulfilledRequest: (UInt64, Bool)?
    coordinator.onFulfillRequest = { request, appliesScroll in
      fulfilledRequest = (request.id, appliesScroll)
    }

    #expect(coordinator.updateRequest(request))
    let initialResult = coordinator.applyRequest(from: applicatorView)

    #expect(initialResult == .needsRetry)
    #expect(fulfilledRequest == nil)
    #expect(scrollView.contentView.bounds.origin == .zero)
    #expect(scrollView.usesPredominantAxisScrolling == false)

    documentView.frame = CGRect(x: 0, y: 0, width: 2_000, height: 1_600)
    window.layoutIfNeeded()
    rootView.layoutSubtreeIfNeeded()
    documentView.layoutSubtreeIfNeeded()
    let finalResult = coordinator.applyRequest(from: applicatorView)

    #expect(finalResult == .applied)
    #expect(fulfilledRequest?.0 == request.id)
    #expect(fulfilledRequest?.1 == true)
    #expect(scrollView.usesPredominantAxisScrolling == false)
    #expect(abs(scrollView.contentView.bounds.origin.x - request.point.x) < 1.5)
    #expect(abs(scrollView.contentView.bounds.origin.y - request.point.y) < 1.5)
  }

  @MainActor
  @Test("viewport scroll coordinator configures free diagonal scrolling without a pending request")
  func viewportScrollCoordinatorConfigures2DScrollingWithoutPendingRequest() {
    let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let rootView = NSView(frame: frame)
    let scrollView = NSScrollView(frame: frame)
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = true

    let documentView = PolicyCanvasFlippedDocumentView(
      frame: CGRect(x: 0, y: 0, width: 2_000, height: 1_600)
    )
    scrollView.documentView = documentView
    rootView.addSubview(scrollView)

    let applicatorView = PolicyCanvasViewportScrollApplicatorView(frame: .zero)
    let coordinator = PolicyCanvasViewportScrollApplicator.Coordinator()
    applicatorView.coordinator = coordinator
    documentView.addSubview(applicatorView)

    let window = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    window.contentView = rootView
    window.layoutIfNeeded()
    rootView.layoutSubtreeIfNeeded()

    scrollView.usesPredominantAxisScrolling = true
    coordinator.configureScrollViewIfAvailable(from: applicatorView)
    #expect(scrollView.usesPredominantAxisScrolling == false)
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

private final class PolicyCanvasFlippedDocumentView: NSView {
  override var isFlipped: Bool { true }
}
