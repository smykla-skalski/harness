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
    #expect(viewModel.zoom <= PolicyCanvasLayout.maximumZoom)

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
    #expect(
      policyCanvasCommandScrollTargetZoom(
        currentZoom: PolicyCanvasLayout.maximumZoom,
        deltaY: 80
      ) == nil
    )
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
    let hostedContentSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewport+HostedContent.swift"
    )
    let focusPlanSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewport+FocusPlans.swift"
    )
    let nativeHostSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewportNativeHost.swift"
    )
    let nativeScrollViewSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNativeScrollView.swift"
    )
    let nativeHostingViewSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNativeHostingView.swift"
    )
    let centeringClipSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasCenteringClipView.swift"
    )

    #expect(hostedContentSource.contains("PolicyCanvasViewportNativeHost("))
    #expect(hostedContentSource.contains(".frame(maxWidth: .infinity, maxHeight: .infinity)"))
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
    #expect(focusPlanSource.contains("let selectionAnchorPoint ="))
    #expect(source.contains("onZoomChange: { zoom in"))
    #expect(!source.contains("content: AnyView("))
    #expect(coordinatorSource.contains("struct PolicyCanvasViewportHostedSnapshot"))
    #expect(coordinatorSource.contains("@Observable"))
    #expect(coordinatorSource.contains("final class PolicyCanvasViewportHostedState"))
    #expect(coordinatorSource.contains("struct PolicyCanvasViewportHostedRoot: View"))
    #expect(nativeHostSource.contains("struct PolicyCanvasViewportNativeHost: NSViewRepresentable"))
    #expect(nativeHostSource.contains("func sizeThatFits("))
    #expect(nativeScrollViewSource.contains("final class PolicyCanvasNativeScrollView"))
    #expect(nativeScrollViewSource.contains("override var intrinsicContentSize: NSSize"))
    #expect(nativeScrollViewSource.contains("override var fittingSize: NSSize"))
    #expect(nativeHostingViewSource.contains("func policyCanvasFixedFittingSize("))
    #expect(nativeHostingViewSource.contains("sizingOptions = []"))
    // Regression guard: the one-shot `requiresHostedLayout` layout gate must not
    // come back. It skipped `super.layout()` for live-observed interaction state
    // (selection, hover, marquee, rubber band) that is excluded from the render
    // signature, freezing those repaints - clicking a node showed no selection
    // and the hover overlay never updated. NSHostingView's own invalidation
    // drives hosted layout instead.
    #expect(!nativeHostingViewSource.contains("requiresHostedLayout"))
    #expect(nativeHostingViewSource.contains("func replaceRootView("))
    #expect(coordinatorSource.contains("guard workspaceLayout != self.workspaceLayout else"))
    #expect(
      coordinatorSource.contains("guard frame.size != size || hostingView.frame.size != size"))
    #expect(coordinatorSource.contains("if hostingView.frame != bounds"))
    #expect(nativeScrollViewSource.contains("PolicyCanvasCenteringClipView()"))
    #expect(centeringClipSource.contains("final class PolicyCanvasCenteringClipView"))
    #expect(nativeScrollViewSource.contains("ensureDocumentRoot("))
    #expect(nativeScrollViewSource.contains("hostedDocumentView.rebind(state: state)"))
    #expect(
      coordinatorSource.contains(
        "hostingView.replaceRootView(PolicyCanvasViewportHostedRoot(state: state))"))
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
    #expect(source.contains("request: activeViewportScrollRequest(scrollApplicatorRequest)"))
    #expect(source.contains("viewportCenteringGenerationToConsume: viewportCenteringGeneration"))
    #expect(
      source.contains(
        "viewModel.consumeViewportCenteringRequest(generation: viewportCenteringGeneration)"))
  }

  @Test("canvas switching refreshes stale final routes lazily")
  func viewportRefreshesStaleFinalRoutes() throws {
    let source =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")
    let routeCacheSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewport+AtomicReflow.swift"
    )
    let surfaceSource =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasViewportSurface.swift")
    let hostedContentSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewport+HostedContent.swift"
    )
    let scrollCoordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(source.contains("@State private var routeCache = PolicyCanvasViewportRouteCache()"))
    #expect(
      source.contains(
        "let centeringRouteState = PolicyCanvasViewportCenteringRouteState("
      )
    )
    #expect(source.contains(".task(id: centeringRouteState)"))
    #expect(source.contains("await centerViewportAfterRouteStateSettles("))
    #expect(source.contains("await Task.yield()"))
    #expect(source.contains("guard !Task.isCancelled else"))
    #expect(source.contains("currentRouteKey: routeKey"))
    #expect(source.contains("let resolvedRouteCache = policyCanvasViewportResolvedRouteCache("))
    #expect(source.contains("let appliedRouteKey = resolvedRouteCache.appliedRouteKey"))
    #expect(source.contains("appliedRouteKey: appliedRouteKey"))
    #expect(source.contains("viewportCenteringGeneration: viewModel.viewportCenteringGeneration"))
    #expect(!source.contains("PolicyCanvasRouteWorkerOutput.fallback("))
    #expect(!source.contains("policyCanvasProvisionalRouteOutput("))
    #expect(!source.contains("policyCanvasNodeBoundsPlaceholderOutput("))
    #expect(!source.contains("routeOutputIsCurrentGraphProvisional"))
    #expect(!source.contains("allowsProvisionalRouteOutput"))
    #expect(source.contains("let routeOutput = projectedRouteResult.output"))
    #expect(source.contains("let finalRouteOutputReady ="))
    #expect(
      source.contains(
        "!viewModel.isEmpty && !routeKeyIsStale && routeOutput.signature != .empty"))
    #expect(source.contains("let hasRenderableRouteOutput ="))
    #expect(source.contains("viewModel.isEmpty || finalRouteOutputReady"))
    #expect(source.contains("let routeOutputMatchesCurrentGraph ="))
    #expect(source.contains("projectedRouteResult.matchesCurrentGraphShape"))
    #expect(source.contains("routeKeyIsStale && routeOutputMatchesCurrentGraph"))
    #expect(source.contains("routeOutputMatchesCurrentGraph: routeOutputMatchesCurrentGraph"))
    #expect(source.contains("hasRenderableRouteOutput: hasRenderableRouteOutput"))
    #expect(source.contains("var routeSeed: PolicyCanvasViewportRouteSeed?"))
    #expect(source.contains("onFinalRouteOutputReady()"))
    #expect(source.contains(".task(id: routeSeed?.id)"))
    #expect(routeCacheSource.contains("updateCachedRoutes("))
    #expect(
      hostedContentSource.contains(
        "isEnabled: showsQualityInspection && snapshot.hasRenderableRouteOutput"))
    #expect(
      scrollCoordinatorSource.contains("if snapshot.hasRenderableRouteOutput {"))
    #expect(source.contains("routeCache.outputsByCanvasIdentity"))
    #expect(
      source.contains("let cachedRouteOutput = routeCache.outputsByCanvasIdentity[newIdentity]"))
    #expect(source.contains(".onChange(of: viewModel.routeComputationRequestGeneration"))
    #expect(source.contains("await rebuildRoutes("))
    #expect(source.contains("pipelineIdentity: routeCacheIdentity"))
    #expect(source.contains("fontScale: fontScale"))
    #expect(source.contains("PolicyCanvasViewportRouteRefreshKey("))
    #expect(source.contains("let routeKeyIsStale = appliedRouteKey != routeKey"))
    #expect(source.contains("let hasActivePositionDrag = viewModel.hasActivePositionDrag"))
    #expect(source.contains("let projectedRouteResult = policyCanvasProjectedRouteResult("))
    #expect(!source.contains("suppressesProjection: hasActivePositionDrag"))
    #expect(!source.contains("let routeProjectionSuppressed"))
    #expect(
      source.contains(
        "let routeProjectionCanCommit ="
      )
    )
    #expect(source.contains("routeKeyIsStale && projectedRouteResult.canCommitAsCurrentGraph"))
    #expect(
      source.contains(
        "!hasActivePositionDrag"
          + "\n        && (routeOutputIsCurrentGraphMissing || (routeKeyIsStale && !routeProjectionCanCommit))"
      )
    )
    #expect(source.contains("PolicyCanvasViewportRouteProjectionCommitKey("))
    #expect(source.contains("guard routeProjectionCanCommit else { return }"))
    #expect(source.contains("nodePositionsByID: policyCanvasNodePositionsByID(nodes)"))
    #expect(source.contains("!viewModel.hasActivePositionDrag"))
    #expect(source.contains("needsRefresh: routeOutputNeedsRefresh"))
    #expect(source.contains("guard routeOutputNeedsRefresh else { return }"))
    #expect(!surfaceSource.contains("forcesAutoArrange"))
    #expect(!surfaceSource.contains("viewModel.reflowLayout("))
    #expect(
      !source.contains(".onChange(of: viewModel.viewportCenteringGeneration, initial: false)"))
  }

  @Test("lab viewport surface keeps document import out of SwiftUI init")
  func labViewportSurfaceDefersDocumentImportOutOfInit() throws {
    let surfaceSource =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasViewportSurface.swift")
    let initializer = try sourceFunction(named: "public init(", in: surfaceSource)

    #expect(surfaceSource.contains("@State private var appliedSnapshot:"))
    #expect(surfaceSource.contains(".task(id: renderKey)"))
    #expect(surfaceSource.contains("await applySurfaceSnapshot(renderKey.snapshot"))
    #expect(surfaceSource.contains("private func applySurfaceSnapshot("))
    #expect(surfaceSource.contains("@State private var routeSeed:"))
    #expect(surfaceSource.contains("applyForcedEngineSurfaceSnapshot("))
    #expect(surfaceSource.contains("policyCanvasAtomicReflowRoutePlan("))
    #expect(surfaceSource.contains("routeWorker: PolicyCanvasRouteWorker()"))
    #expect(surfaceSource.contains("routesCurrentGraphWhenUnchanged: true"))
    #expect(!surfaceSource.contains("policyCanvasFastPrecomputedRouteOutput"))
    #expect(surfaceSource.contains("PolicyCanvasViewportRouteSeed("))
    #expect(surfaceSource.contains("markPolicyCanvasLabReadyIfNeeded"))
    #expect(surfaceSource.contains("HARNESS_MONITOR_POLICY_LAB_READY_FILE"))
    #expect(surfaceSource.contains("PolicyCanvasViewportSurfaceDocumentIdentity"))
    #expect(surfaceSource.contains("private var holdsViewportUntilFinalRoute: Bool"))
    #expect(surfaceSource.contains("PolicyCanvasPendingFinalRouteSurface()"))
    #expect(
      surfaceSource.contains(
        "surfaceForcesEngineLayout\n      && document?.nodes.isEmpty == false"
      )
    )
    #expect(surfaceSource.contains("&& appliedSnapshot != snapshot"))
    #expect(
      initializer.contains("document: nil,\n        simulation: nil,\n        audit: nil,")
    )
    #expect(
      !surfaceSource.contains(
        """
        private struct PolicyCanvasViewportSurfaceSnapshot: Equatable {
          let document: TaskBoardPolicyPipelineDocument?
          let simulation: TaskBoardPolicyPipelineSimulationResult?
          let audit: TaskBoardPolicyPipelineAuditSummary?
        """
      )
    )
    #expect(
      !initializer.contains(
        "document: document,\n        simulation: simulation,\n        audit: audit,")
    )
    #expect(!surfaceSource.contains("documentIdentity: document,"))
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
    #expect(snapshotFunction.contains("guard !viewModel.isSavingDraft else"))
    #expect(snapshotFunction.contains("viewModel.applyPersistedDocument("))
    #expect(!snapshotFunction.contains("forceDocumentReload: true"))
  }

  @Test("port columns render explicit marker sides even when visibility misses them")
  func portColumnsRenderExplicitMarkerSides() throws {
    let source = try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasPortViews.swift")
    let nodeLayerSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNodeLayer.swift"
    )

    #expect(source.contains("let hasRoutedMarkers = markerLayout.hasMarkers"))
    #expect(source.contains("routedSides.contains(side) || hasRoutedMarkers"))
    #expect(source.contains(".contains(side) || hasRoutedMarkers"))
    #expect(nodeLayerSource.contains("ports: node.inputPorts,\n        alignment: .trailing"))
    #expect(nodeLayerSource.contains("ports: node.outputPorts,\n        alignment: .leading"))
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
    let workspaceSource =
      try previewableSourceFile(named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews.swift")
    let focusPlanSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewport+FocusPlans.swift"
    )
    let centeringPlanFunction = try sourceFunction(
      named: "func policyCanvasViewportCenteringPlan",
      in: focusPlanSource
    )
    let restoreOffset =
      centeringPlanFunction.range(of: "anchorPoint: restoredViewportOrigin")?.lowerBound
      ?? centeringPlanFunction.endIndex
    let delayedFallbackOffset =
      centeringPlanFunction.range(of: "defersScrollUntilNextRunloop: true")?.lowerBound
      ?? centeringPlanFunction.startIndex

    #expect(centeringPlanFunction.contains("anchorPoint: restoredViewportOrigin"))
    #expect(workspaceSource.contains("if plan.defersScrollUntilNextRunloop"))
    #expect(workspaceSource.contains("await Task.yield()"))
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
    let focusPlanSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewport+FocusPlans.swift"
    )
    let centeringPlanFunction = try sourceFunction(
      named: "func policyCanvasViewportCenteringPlan",
      in: focusPlanSource
    )

    #expect(sceneStorageSource.contains("var viewportOriginX: Double?"))
    #expect(sceneStorageSource.contains("var viewportOriginY: Double?"))
    #expect(sceneStorageSource.contains("var viewportOrigin: CGPoint?"))
    #expect(layoutSource.contains("persistViewportState: { viewportState, identity in"))
    #expect(layoutSource.contains("persistSceneStorageIfNeeded(viewportState, for: identity)"))
    #expect(workspaceSource.contains("persistViewportState(observedState, observedIdentity)"))
    #expect(
      centeringPlanFunction.contains(
        "let usesRestoredViewportState =\n    input.viewModel.viewportCenteringBehavior.usesRestoredViewportOrigin"
      )
    )
    #expect(
      centeringPlanFunction.contains("restoredSceneState == nil || !usesRestoredViewportState"))
    #expect(
      centeringPlanFunction.contains("if usesRestoredViewportState, let restoredViewportOrigin"))
    #expect(centeringPlanFunction.contains("anchorPoint: restoredViewportOrigin"))
    #expect(centeringPlanFunction.contains("policyCanvasInitialViewportDocumentAnchorPoint"))
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
    #expect(nativeHostSource.contains("onViewportChange?(pending.state, pending.identity)"))
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

  @Test("viewport delivery is deferred off the representable update pass and debounced")
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
    // debounce instead of spawning a publish per scroll callback.
    #expect(
      nativeHostSource.contains("pendingObservedState = (currentViewportIdentity, observedState)")
    )
    #expect(nativeHostSource.contains("private static let viewportChangeDebounceDelayNanoseconds"))
    #expect(nativeHostSource.contains("viewportFlushTask?.cancel()"))
    #expect(nativeHostSource.contains("flushPendingViewportChange()"))
    #expect(nativeHostSource.contains("onViewportChange?(pending.state, pending.identity)"))
  }

  @Test("live viewport observation stays out of core graph layers")
  func liveViewportObservationStaysOutOfCoreGraphLayers() throws {
    let minimapViewportSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasMinimapViewportOverlay.swift"
    )
    let nodeLayerSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNodeLayer.swift"
    )
    let edgeLayerSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasEdgeLayers.swift"
    )
    let simulationLayerSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasSimulationLayer.swift"
    )

    #expect(minimapViewportSource.contains("observationStore.observedState(for: viewportIdentity)"))
    #expect(!nodeLayerSource.contains("policyCanvasViewportCullRect("))
    #expect(!edgeLayerSource.contains("policyCanvasViewportCullRect("))
    #expect(!simulationLayerSource.contains("policyCanvasViewportCullRect("))
    #expect(!nodeLayerSource.contains("PolicyCanvasViewportObservationStore"))
    #expect(!edgeLayerSource.contains("PolicyCanvasViewportObservationStore"))
    #expect(!simulationLayerSource.contains("PolicyCanvasViewportObservationStore"))
  }

  @Test("native document hit testing uses cheap pointer target lookup")
  func nativeDocumentHitTestingUsesCheapPointerTargetLookup() throws {
    let pointerRoutingSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNativeDocumentView+PointerRouting.swift"
    )
    let scrollCoordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )
    let hitTestingSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasViewModel+HitTesting.swift"
    )
    let pointerTargetFunction = try sourceFunction(
      named: "func pointerTarget(at point: CGPoint)",
      in: pointerRoutingSource
    )
    let cheapHitTargetFunction = try sourceFunction(
      named: "func canvasPointerHitTarget",
      in: hitTestingSource
    )

    #expect(pointerTargetFunction.contains("canvasPointerHitTarget("))
    #expect(!pointerTargetFunction.contains("canvasHitTarget("))
    let hitTestFunction = try sourceFunction(
      named: "func hitTestTarget(",
      in: scrollCoordinatorSource
    )
    #expect(scrollCoordinatorSource.contains("shouldResolveInteractiveMouseHitTest"))
    #expect(
      scrollCoordinatorSource.contains(
        "hitTestTarget(at: point, allowsSwiftUIPortHitTesting:"
      )
    )
    #expect(scrollCoordinatorSource.contains("case .leftMouseDown, .leftMouseDragged"))
    #expect(hitTestFunction.contains("guard allowsSwiftUIPortHitTesting else"))
    #expect(hitTestFunction.contains("if case .port"))
    #expect(hitTestFunction.contains("return hostingView"))
    #expect(hitTestFunction.contains("return self"))
    #expect(!hitTestFunction.contains("routes:"))
    #expect(!hitTestFunction.contains("super.hitTest(point)"))
    #expect(cheapHitTargetFunction.contains("nodeFrame.insetBy("))
    #expect(
      cheapHitTargetFunction.contains(
        "canvasPortHitTarget(\n          at: point,\n          node: node,"))
    #expect(cheapHitTargetFunction.contains("canvasEdgeHitTarget(at: point, routes: routes)"))
  }

  @Test("dense graph primitives do not install SwiftUI hover or tooltip responders")
  func denseGraphPrimitivesDoNotInstallSwiftUIHoverOrTooltipResponders() throws {
    let interactiveEdgeSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasInteractiveEdge.swift"
    )
    let nodeLayerSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasNodeLayer.swift"
    )
    let portViewSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasPortViews.swift"
    )
    let simulationLayerSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasSimulationLayer.swift"
    )

    #expect(!interactiveEdgeSource.contains(".onHover"))
    #expect(!interactiveEdgeSource.contains(".help("))
    #expect(!nodeLayerSource.contains(".onHover"))
    #expect(!portViewSource.contains(".help("))
    #expect(!simulationLayerSource.contains(".help("))
  }

  @Test("dense graphs render animated edges statically")
  func denseGraphsRenderAnimatedEdgesStatically() throws {
    let edgeLayerSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasEdgeLayers.swift"
    )
    let interactiveEdgeSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasInteractiveEdge.swift"
    )

    #expect(edgeLayerSource.contains("private let policyCanvasAnimatedEdgeTimelineLimit"))
    #expect(edgeLayerSource.contains("private let policyCanvasDenseEdgeCanvasLimit"))
    #expect(edgeLayerSource.contains("PolicyCanvasDenseEdgeCanvas("))
    #expect(edgeLayerSource.contains("private struct PolicyCanvasDenseEdgeCanvas: View"))
    #expect(edgeLayerSource.contains("PolicyCanvasDenseEdgeDrawingSurface(items: drawingItems)"))
    #expect(
      edgeLayerSource.contains(
        "private struct PolicyCanvasDenseEdgeDrawingSurface: NSViewRepresentable")
    )
    #expect(
      edgeLayerSource.contains("private final class PolicyCanvasDenseEdgeDrawingView: NSView")
    )
    #expect(edgeLayerSource.contains("override func draw(_ dirtyRect: NSRect)"))
    #expect(
      edgeLayerSource.contains(
        "let allowsAnimatedEdgeTimelines = edges.count <= policyCanvasAnimatedEdgeTimelineLimit"
      )
    )
    #expect(edgeLayerSource.contains("isAnimated: edge.isAnimated && allowsAnimatedEdgeTimelines"))
    #expect(edgeLayerSource.contains("private let policyCanvasSwiftUIEdgeContextMenuLimit"))
    #expect(
      edgeLayerSource.contains(
        "let allowsSwiftUIEdgeContextMenus = edges.count <= policyCanvasSwiftUIEdgeContextMenuLimit"
      )
    )
    #expect(edgeLayerSource.contains("allowsContextMenu: allowsSwiftUIEdgeContextMenus"))
    #expect(edgeLayerSource.contains(".equatable()"))
    #expect(interactiveEdgeSource.contains("struct PolicyCanvasInteractiveEdge: View, Equatable"))
    #expect(interactiveEdgeSource.contains("nonisolated static func == ("))
    #expect(interactiveEdgeSource.contains("func policyCanvasEdgeContextMenu("))
  }

  @Test("dense edge canvas uses routed content size")
  func denseEdgeCanvasUsesRoutedContentSize() throws {
    let edgeLayerSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasEdgeLayers.swift"
    )
    let scrollCoordinatorSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasWorkspaceViews+ScrollCoordinator.swift"
    )

    #expect(edgeLayerSource.contains("let contentSize: CGSize"))
    #expect(edgeLayerSource.contains("width: contentSize.width"))
    #expect(edgeLayerSource.contains("height: contentSize.height"))
    #expect(!edgeLayerSource.contains("width: viewModel.canvasContentSize.width"))
    #expect(!edgeLayerSource.contains("height: viewModel.canvasContentSize.height"))
    #expect(scrollCoordinatorSource.contains("contentSize: snapshot.contentSize"))
  }

  @Test("edge strokes keep a readable screen width at far zoom")
  func edgeStrokesKeepReadableScreenWidthAtFarZoom() {
    let farZoom = CGFloat(0.17)
    let width = PolicyCanvasEdgeStrokeMetrics.visibleStrokeWidth(
      baseWidth: 2,
      isSelected: false,
      canvasZoom: farZoom
    )

    #expect(width > 2)
    #expect(abs((width * farZoom) - PolicyCanvasEdgeStrokeMetrics.minimumScreenStrokeWidth) < 0.001)
    #expect(
      PolicyCanvasEdgeStrokeMetrics.visibleStrokeWidth(
        baseWidth: 2,
        isSelected: false,
        canvasZoom: 1
      ) == 2
    )
  }

  @Test("dense document overlays avoid full-size SwiftUI canvas layers")
  func denseDocumentOverlaysAvoidFullSizeSwiftUICanvasLayers() throws {
    let edgeLayerSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasEdgeLayers.swift"
    )
    let qualityOverlaySource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasQualityOverlayLayer.swift"
    )
    let qualityHoverSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasQualityHoverLayer.swift"
    )
    let qualityOverlaySupportSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasQualityOverlayDrawingSupport.swift"
    )
    let drawingSupportSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasAppKitDrawingSupport.swift"
    )

    #expect(edgeLayerSource.contains("PolicyCanvasDenseEdgeDrawingSurface(items: drawingItems)"))
    #expect(qualityOverlaySource.contains("PolicyCanvasQualityOverlaySurface(report: report)"))
    #expect(
      qualityOverlaySource.contains(
        "private struct PolicyCanvasQualityOverlaySurface: NSViewRepresentable")
    )
    #expect(
      qualityOverlaySource.contains(
        "final class PolicyCanvasQualityOverlayView: NSView")
    )
    #expect(qualityHoverSource.contains("ForEach(active)"))
    #expect(!edgeLayerSource.contains("Canvas { context"))
    #expect(!qualityOverlaySource.contains("Canvas { context"))
    #expect(!qualityOverlaySupportSource.contains("Canvas { context"))
    #expect(!qualityHoverSource.contains("Canvas { context"))
    #expect(drawingSupportSource.contains("policyCanvasApplyTransparentDrawingBacking"))
  }

  @Test("dense document overlays cull AppKit redraws to the dirty rect")
  func denseDocumentOverlaysCullAppKitRedrawsToDirtyRect() throws {
    let edgeLayerSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasEdgeLayers.swift"
    )
    let qualityOverlaySource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasQualityOverlayLayer.swift"
    )
    let qualityOverlaySupportSource = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasQualityOverlayDrawingSupport.swift"
    )

    #expect(edgeLayerSource.contains("let dirtyBounds: CGRect"))
    #expect(edgeLayerSource.contains("guard item.dirtyBounds.intersects(dirtyRect)"))
    #expect(edgeLayerSource.contains("policyCanvasDenseEdgeDirtyBounds("))
    #expect(qualityOverlaySupportSource.contains("qualityMarkIntersectsDirtyRect("))
    #expect(qualityOverlaySource.contains("dirtyRect: dirtyRect"))
    #expect(qualityOverlaySupportSource.contains("portSpacingDirtyRect("))
    #expect(!edgeLayerSource.contains("policyCanvasViewportCullRect("))
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

  @Test("component library pane suggests its width instead of pinning a hard one")
  func componentLibraryPaneSuggestsWidth() throws {
    let source = try previewableSourceFile(
      named: "Views/PolicyCanvas/PolicyCanvasToolRailViews.swift"
    )

    // Regression guard: the tool rail wraps a vertical ScrollView that reports no
    // useful horizontal intrinsic width, so the pane carries its own measured
    // content width. That width must be a *suggested* size the pane yields when
    // space is tight, never a hard `.frame(width:)`. A hard width refused to
    // compress, so narrowing the window below it overflowed the two-pane HStack
    // and the default center alignment slid the canvas left under the sidebar.
    #expect(source.contains("let paneWidth = Self.libraryPaneWidth(metrics: metrics)"))
    #expect(source.contains("idealWidth: paneWidth"))
    #expect(source.contains("maxWidth: paneWidth"))
    #expect(!source.contains("width: Self.libraryPaneWidth(metrics: metrics)"))
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
    let endMarkers = ["\nfunc ", "\n  func ", "\n  private func "]
    let end =
      endMarkers
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
      hasRenderableRouteOutput: routeOutput.signature != .empty,
      openEditor: { _ in },
      requestKeyboardFocus: {}
    )
  }
}
