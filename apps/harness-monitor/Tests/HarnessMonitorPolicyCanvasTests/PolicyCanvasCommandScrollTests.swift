import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

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
    #expect(viewModel.zoom >= PolicyCanvasLayout.minimumZoom)
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
    #expect(
      policyCanvasCommandScrollTargetZoom(
        currentZoom: PolicyCanvasLayout.minimumZoom,
        deltaY: -80
      ) == nil
    )
  }

  @Test("viewport uses the native AppKit magnification host")
  func viewportUsesNativeAppKitMagnificationHost() throws {
    let source =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")
    let coordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )
    let nativeHostSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewportNativeHost.swift"
    )
    let nativeScrollViewSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNativeScrollView.swift"
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
    #expect(source.contains("let hostedSnapshot = policyCanvasViewportHostedSnapshot("))
    #expect(source.contains("let selectionScrollPoint ="))
    #expect(source.contains("onZoomChange: { zoom in"))
    #expect(!source.contains("content: AnyView("))
    #expect(coordinatorSource.contains("struct PolicyCanvasViewportHostedSnapshot"))
    #expect(coordinatorSource.contains("@Observable"))
    #expect(coordinatorSource.contains("final class PolicyCanvasViewportHostedState"))
    #expect(coordinatorSource.contains("struct PolicyCanvasViewportHostedRoot: View"))
    #expect(nativeHostSource.contains("struct PolicyCanvasViewportNativeHost: NSViewRepresentable"))
    #expect(nativeScrollViewSource.contains("final class PolicyCanvasNativeScrollView"))
    #expect(nativeScrollViewSource.contains("final class PolicyCanvasCenteringClipView"))
    #expect(nativeScrollViewSource.contains("ensureDocumentRoot("))
    #expect(nativeScrollViewSource.contains("hostedDocumentView.rebind(state: state)"))
    #expect(
      coordinatorSource.contains(
        "hostingView.rootView = PolicyCanvasViewportHostedRoot(state: state)"))
    #expect(nativeScrollViewSource.contains("setMagnification(targetZoom, centeredAt: anchor)"))
    #expect(
      nativeScrollViewSource.contains("documentView.convert(event.locationInWindow, from: nil)"))
    #expect(nativeScrollViewSource.contains("guard interactionEnabled else"))
    #expect(!coordinatorSource.contains("addLocalMonitorForEvents"))
    #expect(nativeScrollViewSource.contains("event.modifierFlags.contains(.command)"))
    #expect(!nativeScrollViewSource.contains("event.modifierFlags.contains(.shift)"))
    #expect(nativeScrollViewSource.contains("policyCanvasCommandScrollDeltaY(event: event)"))
    #expect(nativeScrollViewSource.contains("usesPredominantAxisScrolling = false"))
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

  @Test("canvas switching does not run the route worker automatically")
  func viewportRoutesOnlyAfterExplicitReformatRequest() throws {
    let source =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")
    let surfaceSource =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasViewportSurface.swift")

    #expect(source.contains("@State private var appliedRouteKey: PolicyCanvasRouteWorkerKey?"))
    #expect(
      source.contains(
        "let centeringRouteState = PolicyCanvasViewportCenteringRouteState("
      )
    )
    #expect(source.contains(".onChange(of: centeringRouteState, initial: false)"))
    #expect(source.contains("currentRouteKey: routeKey"))
    #expect(source.contains("appliedRouteKey: appliedRouteKey"))
    #expect(source.contains("viewportCenteringGeneration: viewModel.viewportCenteringGeneration"))
    #expect(source.contains("PolicyCanvasRouteWorkerOutput.fallback(for: routeInput)"))
    #expect(source.contains("cachedRouteOutputsByCanvasIdentity"))
    #expect(source.contains("let cachedRouteOutput = cachedRouteOutputsByCanvasIdentity[newIdentity]"))
    #expect(source.contains("cachedRouteOutputsByCanvasIdentity[pipelineIdentity] ="))
    #expect(source.contains(".onChange(of: viewModel.routeComputationRequestGeneration"))
    #expect(
      source.contains("await rebuildRoutes(for: routeKey, pipelineIdentity: routeCacheIdentity)"))
    #expect(!source.contains(".task(id: routeKey)"))
    #expect(!surfaceSource.contains("forcesAutoArrange"))
    #expect(!surfaceSource.contains("viewModel.reflowLayout("))
    #expect(
      !source.contains(".onChange(of: viewModel.viewportCenteringGeneration, initial: false)"))
  }

  @Test("canvas pane switching uses the persisted document apply path")
  func canvasPaneSwitchingUsesPersistedDocumentApplyPath() throws {
    let selectionPreviewSource = try previewableSourceFile(
      named: "Views/Dashboard/DashboardPolicyCanvasRouteView+IO.swift"
    )
    let actionsSource =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasView+Actions.swift")
    let snapshotFunction = try sourceFunction(
      named: "func applyDashboardSnapshot()",
      in: actionsSource
    )

    #expect(selectionPreviewSource.contains("policyCanvasViewModel.applyPersistedDocument("))
    #expect(!selectionPreviewSource.contains("forceDocumentReload: true"))
    #expect(snapshotFunction.contains("viewModel.applyPersistedDocument("))
    #expect(!snapshotFunction.contains("forceDocumentReload: true"))
  }

  @Test("canvas pane switching keeps the viewport mounted")
  func canvasPaneSwitchingKeepsTheViewportMounted() throws {
    let source =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasView.swift")

    #expect(!source.contains(".optionalID(viewModel.pipelineIdentity)"))
    #expect(!source.contains(".task(id: viewModel.pipelineIdentity)"))
    #expect(source.contains(".task {"))
    #expect(source.contains(".onChange(of: viewModel.pipelineIdentity)"))
  }

  @Test("canvas pane switching restores stored viewport before delayed first-open centering")
  func canvasPaneSwitchingRestoresStoredViewportBeforeDelayedFirstOpenCentering() throws {
    let source =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")
    let centeringFunction = try sourceFunction(
      named: "private func centerViewportIfNeeded",
      in: source
    )
    let restoreOffset =
      centeringFunction.range(of: "requestViewportScroll(to: restoredViewportOrigin")?.lowerBound
      ?? centeringFunction.endIndex
    let delayedFallbackOffset =
      centeringFunction.range(of: "Task { @MainActor in")?.lowerBound
      ?? centeringFunction.startIndex

    #expect(centeringFunction.contains("requestViewportScroll(to: restoredViewportOrigin"))
    #expect(centeringFunction.contains("await Task.yield()"))
    #expect(restoreOffset < delayedFallbackOffset)
  }

  @Test("canvas pane switching restores the stored viewport instead of recentering")
  func canvasPaneSwitchingRestoresTheStoredViewportInsteadOfRecentering() throws {
    let sceneStorageSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView+SceneStorage.swift"
    )
    let layoutSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView+Layout.swift"
    )
    let workspaceSource =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")
    let centeringFunction = try sourceFunction(
      named: "private func centerViewportIfNeeded",
      in: workspaceSource
    )

    #expect(sceneStorageSource.contains("var viewportOriginX: Double?"))
    #expect(sceneStorageSource.contains("var viewportOriginY: Double?"))
    #expect(sceneStorageSource.contains("var viewportOrigin: CGPoint?"))
    #expect(layoutSource.contains("persistViewportState: { viewportState, identity in"))
    #expect(layoutSource.contains("persistSceneStorageIfNeeded(viewportState, for: identity)"))
    #expect(workspaceSource.contains("persistViewportState(observedState, observedIdentity)"))
    #expect(
      centeringFunction.contains(
        "let usesRestoredViewportState = viewModel.viewportCenteringBehavior.usesRestoredViewportOrigin"
      )
    )
    #expect(centeringFunction.contains("restoredSceneState == nil || !usesRestoredViewportState"))
    #expect(centeringFunction.contains("if usesRestoredViewportState, let restoredViewportOrigin"))
    #expect(centeringFunction.contains("requestViewportScroll(to: restoredViewportOrigin"))
    #expect(centeringFunction.contains("policyCanvasInitialViewportDocumentScrollPoint"))
  }

  @Test("deferred viewport observations persist under their originating canvas")
  func deferredViewportObservationsPersistUnderTheirOriginatingCanvas() throws {
    let sceneStorageSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView+SceneStorage.swift"
    )
    let workspaceSource =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")
    let nativeHostSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewportNativeHost.swift"
    )

    #expect(sceneStorageSource.contains("for identity: String?"))
    #expect(workspaceSource.contains("viewportIdentity: viewModel.pipelineIdentity"))
    #expect(workspaceSource.contains("observedState, observedIdentity in"))
    #expect(workspaceSource.contains("persistViewportState(observedState, observedIdentity)"))
    #expect(nativeHostSource.contains("var viewportIdentity: String?"))
    #expect(
      nativeHostSource.contains("pendingObservedState = (currentViewportIdentity, observedState)")
    )
    #expect(nativeHostSource.contains("self.onViewportChange?(pending.state, pending.identity)"))
  }

  @Test("minimap switch snapshots use identity-scoped viewport state")
  func minimapSwitchSnapshotsUseIdentityScopedViewportState() throws {
    let sceneStorageSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasView+SceneStorage.swift"
    )
    let workspaceSource =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")
    let minimapViewportSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasMinimapViewportOverlay.swift"
    )
    let overlayModifierSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewportOverlayModifier.swift"
    )

    #expect(sceneStorageSource.contains("var viewportWidth: Double?"))
    #expect(sceneStorageSource.contains("var viewportHeight: Double?"))
    #expect(sceneStorageSource.contains("var viewportRect: CGRect?"))
    #expect(sceneStorageSource.contains("guard previousState != state else"))
    #expect(minimapViewportSource.contains("func observedState(for identity: String?)"))
    #expect(minimapViewportSource.contains("func update("))
    #expect(minimapViewportSource.contains("viewportIdentity: String?"))
    #expect(minimapViewportSource.contains("storedPipelineStateRaw: String"))
    #expect(minimapViewportSource.contains("observationStore.observedState(for: viewportIdentity)"))
    #expect(minimapViewportSource.contains("restoredViewportRect"))
    #expect(
      !minimapViewportSource.contains(
        "observationStore.observedState?.visibleContentRect ?? contentBounds"
      )
    )
    #expect(workspaceSource.contains("viewportObservationStore.update(observedState, for:"))
    #expect(workspaceSource.contains("matchesRestoredMinimapViewport"))
    #expect(workspaceSource.contains("policyCanvasMinimapViewportMatchesRestoredSceneState"))
    #expect(workspaceSource.contains("if !matchesRestoredMinimapViewport"))
    #expect(overlayModifierSource.contains("viewportIdentity: viewModel.pipelineIdentity"))
    #expect(overlayModifierSource.contains("storedPipelineStateRaw: storedPipelineStateRaw"))
  }

  @Test("background deselection lives on the grid layer so component taps win")
  func viewportBackgroundDeselectionLivesOnGridLayer() throws {
    let coordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(coordinatorSource.contains("PolicyCanvasBackgroundSurface()"))
    #expect(coordinatorSource.contains(".contentShape(Rectangle())"))
    #expect(coordinatorSource.contains(".onTapGesture {"))
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

  @Test("canvas background surface uses AppKit dirty-rect drawing instead of workspace-wide Canvas")
  func canvasBackgroundSurfaceUsesAppKitDirtyRectDrawing() throws {
    let gridSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasGridLayers.swift"
    )

    #expect(gridSource.contains("struct PolicyCanvasBackgroundSurface: NSViewRepresentable"))
    #expect(gridSource.contains("final class PolicyCanvasBackgroundSurfaceView: NSView"))
    #expect(gridSource.contains("override func draw(_ dirtyRect: NSRect)"))
    #expect(!gridSource.contains("Canvas {"))
    #expect(!gridSource.contains("fillEllipse"))
  }

  @Test("viewport delivery is deferred off the representable update pass and coalesced")
  func viewportDeliveryIsDeferredOffTheRepresentableUpdatePass() throws {
    let nativeHostSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewportNativeHost.swift"
    )

    #expect(
      nativeHostSource.contains(
        "func handleViewportChange(_ observedState: PolicyCanvasViewportObservedState)"
      )
    )
    // Still deferred off the AppKit scroll-layout pass via a main-actor hop.
    #expect(nativeHostSource.contains("Task { @MainActor in"))
    // Coalesced: keep only the latest state and drain it once per scheduled
    // hop instead of spawning a Task per scroll callback.
    #expect(
      nativeHostSource.contains("pendingObservedState = (currentViewportIdentity, observedState)")
    )
    #expect(nativeHostSource.contains("guard !hasScheduledViewportFlush else"))
    #expect(nativeHostSource.contains("self.onViewportChange?(pending.state, pending.identity)"))
  }

  @Test("native host retries a pending scroll request until the viewport is ready")
  func viewportNativeHostRetriesPendingRequests() throws {
    let nativeHostSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewportNativeHost.swift"
    )
    let nativeScrollViewSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNativeScrollView.swift"
    )

    #expect(nativeScrollViewSource.contains("case needsRetry"))
    #expect(nativeScrollViewSource.contains("guard contentView.bounds.width > 1"))
    #expect(nativeHostSource.contains("scheduleRetry(on: scrollView, request: request)"))
    #expect(nativeHostSource.contains("DispatchQueue.main.async"))
  }

  @Test("zero-delta short-circuits and reports no change")
  func zeroDeltaIsRejected() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.setZoom(1)
    #expect(viewModel.zoomByCommandScroll(deltaY: 0) == false)
    #expect(viewModel.zoom == 1)
  }

  func previewableSourceFile(named path: String) throws -> String {
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

  func sourceFunction(named marker: String, in source: String) throws -> String {
    guard let start = source.range(of: marker) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let remaining = source[start.upperBound...]
    let endMarkers = ["\n  func ", "\n  private func "]
    let end = endMarkers
      .compactMap { remaining.range(of: $0)?.lowerBound }
      .min()
    guard let end else {
      return String(source[start.lowerBound...])
    }
    return String(source[start.lowerBound..<end])
  }

  func hostedSnapshot(
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
