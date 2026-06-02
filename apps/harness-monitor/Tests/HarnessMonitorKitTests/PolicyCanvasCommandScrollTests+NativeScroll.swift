import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension PolicyCanvasCommandScrollTests {
  @MainActor
  @Test("switching to the pasted PR dry-run canvas recenters the native viewport")
  func switchingToPastedPRDryRunCanvasRecentersTheNativeViewport() async throws {
    let frame = CGRect(x: 0, y: 0, width: 1_200, height: 800)
    let viewModel = PolicyCanvasViewModel.liveStartupState(
      document: TaskBoardPolicyPipelineDocument(
        revision: 1,
        mode: .draft,
        nodes: [],
        edges: [],
        groups: []
      ),
      simulation: nil,
      audit: nil,
      activeCanvasId: "default-canvas"
    )
    let host = NSHostingView(
      rootView: PolicyCanvasViewportSwitchTestHost(viewModel: viewModel)
    )
    let window = NSWindow(
      contentRect: frame,
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    let pastedDocument = policyCanvasPastedPRDryRunDocument()

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    host.frame = frame
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    viewModel.applyDocument(
      document: pastedDocument,
      simulation: nil,
      audit: nil,
      activeCanvasId: "pasted-pr-canvas",
      forceDocumentReload: true
    )

    #expect(
      await waitUntil {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard
          let scrollView = descendant(
            of: host,
            as: PolicyCanvasNativeScrollView.self
          )
        else {
          return false
        }
        return scrollView.contentView.bounds.width > 1
          && scrollView.contentView.bounds.height > 1
      }
    )

    let scrollView = try #require(descendant(of: host, as: PolicyCanvasNativeScrollView.self))
    let viewportSize = scrollView.contentView.bounds.size
    let routeOutput = PolicyCanvasRouteWorkerOutput.fallback(
      for: PolicyCanvasRouteWorkerInput(
        graphGeneration: viewModel.routeComputationGeneration,
        nodes: viewModel.nodes,
        groups: viewModel.groups,
        edges: viewModel.edges,
        fontScale: 1,
        routingHints: viewModel.routingHints,
        algorithmSelection: viewModel.algorithmSelection
      )
    )
    let expectedZoom = min(
      viewModel.zoom,
      viewModel.fittedInitialZoom(for: viewportSize, contentBounds: routeOutput.visibleBounds)
    )
    let expectedDocumentOrigin = policyCanvasInitialViewportDocumentScrollPoint(
      visibleBounds: routeOutput.visibleBounds,
      viewportSize: viewportSize,
      zoom: expectedZoom
    )
    #expect(
      await waitUntil {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard
          let scrollView = descendant(
            of: host,
            as: PolicyCanvasNativeScrollView.self
          )
        else {
          return false
        }
        guard let documentView = scrollView.documentView as? PolicyCanvasNativeDocumentView else {
          return false
        }
        let workspaceLayout = documentView.hostedState.workspaceLayout
        let visibleContentRect = workspaceLayout.contentRect(
          forWorkspaceRect: scrollView.contentView.bounds)
        return abs(visibleContentRect.origin.x - expectedDocumentOrigin.x) < 1.5
          && abs(visibleContentRect.origin.y - expectedDocumentOrigin.y) < 1.5
      }
    )

    let actualOrigin = scrollView.contentView.bounds.origin
    let documentView = try #require(scrollView.documentView as? PolicyCanvasNativeDocumentView)
    let workspaceLayout = documentView.hostedState.workspaceLayout
    let liveContentRect = workspaceLayout.contentRect(
      forWorkspaceRect: scrollView.contentView.bounds)
    #expect(
      abs(liveContentRect.origin.x - expectedDocumentOrigin.x) < 1.5,
      """
      Expected centered x content origin \(expectedDocumentOrigin.x), \
      got \(liveContentRect.origin.x); workspaceOrigin=\(actualOrigin.x) \
      viewportSize=\(viewportSize) liveContentRect=\(liveContentRect) \
      contentOrigin=\(workspaceLayout.contentOrigin) workspaceSize=\(workspaceLayout.workspaceSize) \
      contentSize=\(documentView.hostedState.snapshot.contentSize)
      """
    )
    #expect(
      abs(liveContentRect.origin.y - expectedDocumentOrigin.y) < 1.5,
      """
      Expected centered y content origin \(expectedDocumentOrigin.y), \
      got \(liveContentRect.origin.y); workspaceOrigin=\(actualOrigin.y) \
      viewportSize=\(viewportSize) liveContentRect=\(liveContentRect) \
      contentOrigin=\(workspaceLayout.contentOrigin) workspaceSize=\(workspaceLayout.workspaceSize) \
      contentSize=\(documentView.hostedState.snapshot.contentSize)
      """
    )
  }

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
  @Test("native scroll view preserves the visible center when the viewport size changes")
  func nativeScrollViewPreservesTheVisibleCenterWhenTheViewportSizeChanges() {
    let initialFrame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let resizedFrame = CGRect(x: 0, y: 0, width: 860, height: 620)
    let rootView = NSView(frame: initialFrame)
    let scrollView = PolicyCanvasNativeScrollView()
    scrollView.frame = initialFrame
    scrollView.autoresizingMask = [.width, .height]
    scrollView.setTestingDocumentContent(
      Color.clear.frame(width: 2_400, height: 1_800),
      size: CGSize(width: 2_400, height: 1_800)
    )
    rootView.addSubview(scrollView)

    let window = NSWindow(
      contentRect: initialFrame,
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

    let initialResult = scrollView.applyScrollRequest(CGPoint(x: 900, y: 700))
    #expect(initialResult == .applied(true))
    let initialCenter = scrollView.visibleDocumentCenter

    window.setContentSize(resizedFrame.size)
    window.layoutIfNeeded()
    rootView.layoutSubtreeIfNeeded()

    let resizedCenter = scrollView.visibleDocumentCenter
    #expect(abs(resizedCenter.x - initialCenter.x) < 1.5)
    #expect(abs(resizedCenter.y - initialCenter.y) < 1.5)
  }

  @MainActor
  @Test("hosted policy canvas preserves the visible content center when the window resizes")
  func hostedPolicyCanvasPreservesTheVisibleContentCenterWhenTheWindowResizes() async throws {
    let initialFrame = CGRect(x: 0, y: 0, width: 940, height: 660)
    let resizedFrame = CGRect(x: 0, y: 0, width: 1_320, height: 920)
    let viewModel = PolicyCanvasViewModel.liveStartupState(
      document: policyCanvasPastedPRDryRunDocument(),
      simulation: nil,
      audit: nil,
      activeCanvasId: "pasted-pr-canvas"
    )
    viewModel.setZoom(1.2)
    let host = NSHostingView(rootView: PolicyCanvasView(viewModel: viewModel))
    let window = NSWindow(
      contentRect: initialFrame,
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )

    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    host.frame = initialFrame
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    #expect(
      await waitUntil {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        guard let scrollView = descendant(of: host, as: PolicyCanvasNativeScrollView.self) else {
          return false
        }
        return scrollView.contentView.bounds.width > 1
          && scrollView.contentView.bounds.height > 1
          && !viewModel.hasPendingViewportCenteringRequest
      }
    )

    let scrollView = try #require(descendant(of: host, as: PolicyCanvasNativeScrollView.self))
    #expect(scrollView.applyScrollRequest(CGPoint(x: 900, y: 700)) == .applied(true))
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    let initialViewportSize = scrollView.contentView.bounds.size
    let initialContentCenter = try visibleContentCenter(in: scrollView)

    window.setContentSize(resizedFrame.size)
    #expect(
      await waitUntil {
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        return abs(scrollView.contentView.bounds.width - initialViewportSize.width) > 1
          || abs(scrollView.contentView.bounds.height - initialViewportSize.height) > 1
      }
    )

    let resizedContentCenter = try visibleContentCenter(in: scrollView)
    #expect(
      abs(resizedContentCenter.x - initialContentCenter.x) < 1.5,
      "Expected x center \(initialContentCenter.x), got \(resizedContentCenter.x)"
    )
    #expect(
      abs(resizedContentCenter.y - initialContentCenter.y) < 1.5,
      "Expected y center \(initialContentCenter.y), got \(resizedContentCenter.y)"
    )
  }

  @MainActor
  @Test("adaptive hosted scroll view preserves content center during first viewport growth")
  func adaptiveHostedScrollViewPreservesContentCenterDuringFirstViewportGrowth() throws {
    let initialFrame = CGRect(x: 0, y: 0, width: 640, height: 480)
    let resizedFrame = CGRect(x: 0, y: 0, width: 1_600, height: 1_120)
    let focusedComponent = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let state = PolicyCanvasViewportHostedState(
      snapshot: hostedSnapshot(focusedComponent: focusedComponent)
    )
    let scrollView = PolicyCanvasNativeScrollView()
    scrollView.frame = initialFrame

    let window = NSWindow(
      contentRect: initialFrame,
      styleMask: [.titled, .closable, .resizable],
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

    scrollView.contentView.scroll(
      to: state.workspaceLayout.workspacePoint(
        forContentPoint: CGPoint(x: 700, y: 520)
      )
    )
    let initialContentCenter = try visibleContentCenter(in: scrollView)

    window.setContentSize(resizedFrame.size)
    window.layoutIfNeeded()
    scrollView.layoutSubtreeIfNeeded()
    scrollView.ensureDocumentRoot(state: state, size: state.snapshot.contentSize)

    let resizedContentCenter = try visibleContentCenter(in: scrollView)
    let documentView = try #require(scrollView.documentView as? PolicyCanvasNativeDocumentView)
    let workspaceLayout = documentView.hostedState.workspaceLayout
    let debugMessage = """
      initialCenter=\(initialContentCenter) resizedCenter=\(resizedContentCenter) \
      clipBounds=\(scrollView.contentView.bounds) \
      contentOrigin=\(workspaceLayout.contentOrigin) workspaceSize=\(workspaceLayout.workspaceSize)
      """
    #expect(
      abs(resizedContentCenter.x - initialContentCenter.x) < 1.5,
      "Expected x center \(initialContentCenter.x), got \(resizedContentCenter.x); \(debugMessage)"
    )
    #expect(
      abs(resizedContentCenter.y - initialContentCenter.y) < 1.5,
      "Expected y center \(initialContentCenter.y), got \(resizedContentCenter.y); \(debugMessage)"
    )
  }

  @MainActor
  @Test("native scroll view clip view defers empty-margin background to the parent surface")
  func nativeScrollViewClipViewDefersEmptyMarginBackgroundToTheParentSurface() throws {
    let scrollView = PolicyCanvasNativeScrollView()
    let clipView = try #require(scrollView.contentView as? PolicyCanvasCenteringClipView)

    #expect(scrollView.drawsBackground == false)
    #expect(clipView.drawsBackground == false)
  }

  @MainActor
  @Test("native scroll view uses redraw-safe scroll backing")
  func nativeScrollViewUsesRedrawSafeScrollBacking() throws {
    let scrollView = PolicyCanvasNativeScrollView()
    let clipView = try #require(scrollView.contentView as? PolicyCanvasCenteringClipView)

    #expect(scrollView.horizontalScrollElasticity == .none)
    #expect(scrollView.verticalScrollElasticity == .none)
    #expect(clipView.wantsLayer)
    #expect(clipView.layer?.masksToBounds == true)

    if clipView.responds(to: NSSelectorFromString("copiesOnScroll")) {
      let copiesOnScroll = try #require(clipView.value(forKey: "copiesOnScroll") as? Bool)
      #expect(copiesOnScroll == false)
    }

    scrollView.setInteractionEnabled(false)
    #expect(scrollView.horizontalScrollElasticity == .none)
    #expect(scrollView.verticalScrollElasticity == .none)

    scrollView.setInteractionEnabled(true)
    #expect(scrollView.horizontalScrollElasticity == .none)
    #expect(scrollView.verticalScrollElasticity == .none)
  }

  @MainActor
  @Test("native document host uses opaque clipped layer backing")
  func nativeDocumentHostUsesOpaqueClippedLayerBacking() throws {
    let focusedComponent = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let state = PolicyCanvasViewportHostedState(
      snapshot: hostedSnapshot(focusedComponent: focusedComponent)
    )
    let scrollView = PolicyCanvasNativeScrollView()

    scrollView.ensureDocumentRoot(state: state, size: state.snapshot.contentSize)
    let documentView = try #require(scrollView.documentView as? PolicyCanvasNativeDocumentView)

    #expect(documentView.isOpaque)
    #expect(documentView.wantsLayer)
    #expect(documentView.layer?.masksToBounds == true)
    #expect(documentView.layer?.isOpaque == true)
    #expect(documentView.layer?.backgroundColor != nil)
    #expect(documentView.hostingView.isOpaque)
    #expect(documentView.hostingView.wantsLayer)
    #expect(documentView.hostingView.layer?.masksToBounds == true)
    #expect(documentView.hostingView.layer?.isOpaque == true)
    #expect(documentView.hostingView.layer?.backgroundColor != nil)
  }

  @MainActor
  @Test("native host coalesces AppKit zoom model writes")
  func nativeHostCoalescesAppKitZoomModelWrites() async throws {
    let focusedComponent = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let coordinator = PolicyCanvasViewportNativeHost.Coordinator(
      snapshot: hostedSnapshot(focusedComponent: focusedComponent),
      viewportIdentity: nil
    )
    var deliveredZooms: [CGFloat] = []
    coordinator.onZoomChange = { zoom in
      deliveredZooms.append(zoom)
    }

    coordinator.handleViewportZoomChange(1.05)
    coordinator.handleViewportZoomChange(1.12)

    #expect(deliveredZooms.isEmpty)

    try await Task.sleep(nanoseconds: 80_000_000)

    #expect(deliveredZooms == [1.12])
  }

  @MainActor
  @Test("native host does not replay stale model zoom while user zoom is pending")
  func nativeHostDoesNotReplayStaleModelZoomWhileUserZoomIsPending() async throws {
    let focusedComponent = AccessibilityFocusState<PolicyCanvasSelection?>().projectedValue
    let coordinator = PolicyCanvasViewportNativeHost.Coordinator(
      snapshot: hostedSnapshot(focusedComponent: focusedComponent),
      viewportIdentity: nil
    )
    let scrollView = PolicyCanvasNativeScrollView()
    scrollView.setTestingDocumentContent(
      Color.clear.frame(width: 2_000, height: 1_600),
      size: CGSize(width: 2_000, height: 1_600)
    )
    scrollView.setMagnification(1.2, centeredAt: scrollView.visibleDocumentCenter)
    var deliveredZoom: CGFloat?
    coordinator.onZoomChange = { zoom in
      deliveredZoom = zoom
    }

    coordinator.handleViewportZoomChange(1.2)
    coordinator.applyModelZoomIfNeeded(1.0, to: scrollView)

    #expect(abs(scrollView.magnification - 1.2) < 0.001)

    try await Task.sleep(nanoseconds: 80_000_000)

    #expect(deliveredZoom == 1.2)
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
}

private struct PolicyCanvasViewportSwitchTestHost: View {
  @Bindable var viewModel: PolicyCanvasViewModel
  @AccessibilityFocusState private var focusedComponentState: PolicyCanvasSelection?

  var body: some View {
    PolicyCanvasViewport(
      viewModel: viewModel,
      focusedComponent: $focusedComponentState,
      suppressesSceneStorage: true,
      storedPipelineStateRaw: ""
    )
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .id(viewModel.pipelineIdentity ?? "policy-canvas-switch-test")
  }
}

@MainActor
private func descendant<ViewType: NSView>(
  of root: NSView,
  as type: ViewType.Type
) -> ViewType? {
  if let typedRoot = root as? ViewType {
    return typedRoot
  }
  for subview in root.subviews {
    if let match = descendant(of: subview, as: type) {
      return match
    }
  }
  return nil
}

@MainActor
private func waitUntil(
  timeout: Duration = .seconds(1),
  interval: Duration = .milliseconds(10),
  _ predicate: @escaping @Sendable @MainActor () -> Bool
) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while clock.now < deadline {
    if await MainActor.run(resultType: Bool.self, body: predicate) {
      return true
    }
    await Task.yield()
    try? await Task.sleep(for: interval)
  }
  return await MainActor.run(resultType: Bool.self, body: predicate)
}

@MainActor
private func visibleContentCenter(in scrollView: PolicyCanvasNativeScrollView) throws -> CGPoint {
  let documentView = try #require(scrollView.documentView as? PolicyCanvasNativeDocumentView)
  let rect = documentView.hostedState.workspaceLayout.contentRect(
    forWorkspaceRect: scrollView.contentView.bounds)
  return CGPoint(x: rect.midX, y: rect.midY)
}
