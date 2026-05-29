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

  @Test("viewport uses the native AppKit magnification host")
  func viewportUsesNativeAppKitMagnificationHost() throws {
    let source =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")
    let coordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(source.contains("PolicyCanvasViewportNativeHost("))
    #expect(!source.contains("ScrollView([.horizontal, .vertical])"))
    #expect(!source.contains(".scaleEffect(viewModel.zoom"))
    #expect(!source.contains("PolicyCanvasViewportScrollApplicator("))
    #expect(!source.contains(".onScrollGeometryChange("))
    #expect(!source.contains(".simultaneousGesture(magnifyGesture"))
    #expect(source.contains("await Task.yield()"))
    #expect(!source.contains(".scrollPosition($scrollPosition)"))
    #expect(!source.contains("scrollProxy.scrollTo("))
    #expect(!source.contains("ScrollViewReader {"))
    #expect(source.contains(".task(id: selectionFocusRequest?.id)"))
    #expect(source.contains("let hostedSnapshot = PolicyCanvasViewportHostedSnapshot("))
    #expect(source.contains("let selectionScrollPoint ="))
    #expect(source.contains("onZoomChange: { zoom in"))
    #expect(!source.contains("content: AnyView("))
    #expect(coordinatorSource.contains("struct PolicyCanvasViewportHostedSnapshot"))
    #expect(coordinatorSource.contains("@Observable"))
    #expect(coordinatorSource.contains("final class PolicyCanvasViewportHostedState"))
    #expect(coordinatorSource.contains("struct PolicyCanvasViewportHostedRoot: View"))
    #expect(coordinatorSource.contains("struct PolicyCanvasViewportNativeHost: NSViewRepresentable"))
    #expect(coordinatorSource.contains("final class PolicyCanvasNativeScrollView"))
    #expect(coordinatorSource.contains("final class PolicyCanvasCenteringClipView"))
    #expect(coordinatorSource.contains("ensureDocumentRoot("))
    #expect(coordinatorSource.contains("hostedDocumentView.rebind(state: state)"))
    #expect(coordinatorSource.contains("hostingView.rootView = PolicyCanvasViewportHostedRoot(state: state)"))
    #expect(coordinatorSource.contains("setMagnification(targetZoom, centeredAt: anchor)"))
    #expect(coordinatorSource.contains("documentView.convert(event.locationInWindow, from: nil)"))
    #expect(coordinatorSource.contains("guard interactionEnabled else"))
    #expect(!coordinatorSource.contains("addLocalMonitorForEvents"))
    #expect(coordinatorSource.contains("policyCanvasCommandScrollDeltaY(event: event)"))
    #expect(coordinatorSource.contains("usesPredominantAxisScrolling = false"))
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

  @Test("background deselection lives on the grid layer so component taps win")
  func viewportBackgroundDeselectionLivesOnGridLayer() throws {
    let coordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(
      coordinatorSource.contains(
        """
        PolicyCanvasDottedGrid(spacing: PolicyCanvasLayout.gridSize)
                .contentShape(Rectangle())
                .onTapGesture
        """
      )
    )
    #expect(
      coordinatorSource.contains(
        """
        .dropDestination(for: String.self) { payloads, location in
              snapshot.viewModel.dropPalettePayloads(
                payloads,
                at: workspaceLayout.contentPoint(forWorkspacePoint: location)
              )
            }
            .accessibilityElement(children: .contain)
        """
      )
    )
  }

  @Test("dotted grid uses AppKit dirty-rect drawing instead of workspace-wide Canvas")
  func dottedGridUsesAppKitDirtyRectDrawing() throws {
    let gridSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasGridLayers.swift"
    )

    #expect(gridSource.contains("struct PolicyCanvasDottedGrid: NSViewRepresentable"))
    #expect(gridSource.contains("final class PolicyCanvasDottedGridView: NSView"))
    #expect(gridSource.contains("override func draw(_ dirtyRect: NSRect)"))
    #expect(!gridSource.contains("Canvas {"))
  }

  @Test("viewport delivery is deferred off the representable update pass and coalesced")
  func viewportDeliveryIsDeferredOffTheRepresentableUpdatePass() throws {
    let coordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(
      coordinatorSource.contains(
        "func handleViewportChange(_ observedState: PolicyCanvasViewportObservedState)"
      )
    )
    // Still deferred off the AppKit scroll-layout pass via a main-actor hop.
    #expect(coordinatorSource.contains("Task { @MainActor in"))
    // Coalesced: keep only the latest state and drain it once per scheduled
    // hop instead of spawning a Task per scroll callback.
    #expect(coordinatorSource.contains("pendingObservedState = observedState"))
    #expect(coordinatorSource.contains("guard !hasScheduledViewportFlush else"))
    #expect(coordinatorSource.contains("self.onViewportChange?(pending)"))
  }

  @Test("native host retries a pending scroll request until the viewport is ready")
  func viewportNativeHostRetriesPendingRequests() throws {
    let coordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(coordinatorSource.contains("case needsRetry"))
    #expect(coordinatorSource.contains("guard contentView.bounds.width > 1"))
    #expect(coordinatorSource.contains("scheduleRetry(on: scrollView, request: request)"))
    #expect(coordinatorSource.contains("DispatchQueue.main.async"))
  }

  @MainActor
  @Test("native scroll view recenters after the viewport becomes available")
  func nativeScrollViewRecentersAfterLateLayout() {
    let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let rootView = NSView(frame: frame)
    let scrollView = PolicyCanvasNativeScrollView()

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

    let requestPoint = CGPoint(x: 900, y: 700)
    let initialResult = scrollView.applyScrollRequest(requestPoint)
    #expect(initialResult == .needsRetry)
    #expect(scrollView.contentView.bounds.origin == .zero)
    #expect(scrollView.usesPredominantAxisScrolling == false)

    scrollView.frame = frame
    rootView.addSubview(scrollView)
    scrollView.setTestingDocumentContent(
      Color.clear.frame(width: 2_000, height: 1_600),
      size: CGSize(width: 2_000, height: 1_600)
    )
    window.layoutIfNeeded()
    rootView.layoutSubtreeIfNeeded()
    let finalResult = scrollView.applyScrollRequest(requestPoint)

    #expect(finalResult == .applied(true))
    #expect(scrollView.usesPredominantAxisScrolling == false)
    #expect(abs(scrollView.contentView.bounds.origin.x - requestPoint.x) < 1.5)
    #expect(abs(scrollView.contentView.bounds.origin.y - requestPoint.y) < 1.5)
  }

  @MainActor
  @Test("native scroll view centers a smaller document while keeping free diagonal scrolling")
  func nativeScrollViewCentersSmallerDocument() {
    let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let scrollView = PolicyCanvasNativeScrollView()
    scrollView.frame = frame
    scrollView.setTestingDocumentContent(
      Color.clear.frame(width: 320, height: 240),
      size: CGSize(width: 320, height: 240)
    )

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

    window.contentView = scrollView
    window.layoutIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    #expect(scrollView.usesPredominantAxisScrolling == false)
    #expect(abs(scrollView.contentView.bounds.origin.x + 160) < 1.5)
    #expect(abs(scrollView.contentView.bounds.origin.y + 120) < 1.5)
  }

  @MainActor
  @Test("native scroll view rebinds the hosted root when a reused host gets a new state")
  func nativeScrollViewRebindsHostedRootState() throws {
    let focusedComponent = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let state1 = PolicyCanvasViewportHostedState(
      snapshot: hostedSnapshot(focusedComponent: focusedComponent)
    )
    let state2 = PolicyCanvasViewportHostedState(
      snapshot: hostedSnapshot(focusedComponent: focusedComponent)
    )
    let scrollView = PolicyCanvasNativeScrollView()

    scrollView.ensureDocumentRoot(state: state1, size: state1.snapshot.contentSize)
    let documentView = try #require(scrollView.documentView as? PolicyCanvasNativeDocumentView)
    #expect(documentView.hostedState === state1)
    #expect(documentView.rootViewState === state1)

    scrollView.ensureDocumentRoot(state: state2, size: state2.snapshot.contentSize)

    #expect(documentView.hostedState === state2)
    #expect(documentView.rootViewState === state2)
  }

  @MainActor
  @Test("native scroll view expands the hosted workspace near the trailing edge")
  func nativeScrollViewExpandsHostedWorkspaceNearTrailingEdge() throws {
    let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let focusedComponent = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let state = PolicyCanvasViewportHostedState(
      snapshot: hostedSnapshot(focusedComponent: focusedComponent)
    )
    let scrollView = PolicyCanvasNativeScrollView()
    scrollView.frame = frame

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

    window.contentView = scrollView
    scrollView.ensureDocumentRoot(state: state, size: state.snapshot.contentSize)
    window.layoutIfNeeded()
    scrollView.layoutSubtreeIfNeeded()

    let documentView = try #require(scrollView.documentView)
    let initialWidth = documentView.frame.width

    scrollView.contentView.scroll(
      to: CGPoint(
        x: initialWidth - frame.width - 100,
        y: 0
      )
    )
    scrollView.reflectScrolledClipView(scrollView.contentView)

    #expect(documentView.frame.width > initialWidth)
  }

  @Test("interactive layers use layout positions instead of visual offsets")
  func interactiveLayersUseLayoutPositions() throws {
    let nodeSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNodeLayer.swift"
    )
    let groupSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasGroupViews.swift"
    )
    let simulationSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasSimulationLayer.swift"
    )
    let coordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(!nodeSource.contains(".offset(x: node.position.x, y: node.position.y)"))
    #expect(
      nodeSource.contains("x: node.position.x + PolicyCanvasLayout.nodeSize.width / 2")
    )
    #expect(
      nodeSource.contains("y: node.position.y + PolicyCanvasLayout.nodeSize.height / 2")
    )
    #expect(!groupSource.contains(".offset(x: group.frame.minX, y: group.frame.minY)"))
    #expect(groupSource.contains(".position(x: group.frame.midX, y: group.frame.midY)"))
    #expect(!simulationSource.contains(".offset(x: node.position.x, y: node.position.y)"))
    #expect(
      coordinatorSource
        .components(separatedBy: ".policyCanvasDocumentLayer(size: snapshot.contentSize)")
        .count >= 7
    )
    #expect(
      coordinatorSource
        .contains("frame(width: size.width, height: size.height, alignment: .topLeading)")
    )
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

  private func hostedSnapshot(
    viewModel: PolicyCanvasViewModel = PolicyCanvasViewModel.sample(),
    focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  ) -> PolicyCanvasViewportHostedSnapshot {
    let routeOutput = PolicyCanvasRouteWorkerOutput.fallback(
      for: PolicyCanvasRouteWorkerInput(
        nodes: viewModel.nodes,
        groups: viewModel.groups,
        edges: viewModel.edges,
        fontScale: 1
      )
    )
    return PolicyCanvasViewportHostedSnapshot(
      viewModel: viewModel,
      focusedComponent: focusedComponent,
      edges: viewModel.edges,
      routes: routeOutput.routes,
      labelPositions: routeOutput.labelPositions,
      accessibilityLabelsByEdgeID: routeOutput.accessibilityEdgeLabelsByID,
      accessibilityNodeEntries: routeOutput.accessibilityNodeEntries,
      accessibilityEdgeEntries: routeOutput.accessibilityEdgeEntries,
      nodeAccessibilityValuesByID: routeOutput.nodeAccessibilityValuesByID,
      connectTargetsByNodeID: routeOutput.connectTargetsByNodeID,
      nodeValidationIssueMessagesByID: [:],
      portVisibility: routeOutput.portVisibility,
      portMarkerLayout: routeOutput.portMarkerLayout,
      routeSignature: routeOutput.signature,
      contentSize: routeOutput.contentSize,
      resolvedCanvasColorScheme: nil,
      showSimulationOverlay: false,
      openEditor: { _ in },
      requestKeyboardFocus: {}
    )
  }
}
