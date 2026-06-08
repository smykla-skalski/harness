import HarnessMonitorPolicyCanvasAlgorithms
import SwiftUI

struct PolicyCanvasViewport: View {
  let viewModel: PolicyCanvasViewModel
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  var selectionFocusRequest: PolicyCanvasViewportSelectionFocusRequest?
  var showSimulationOverlay: Bool = false
  var sceneFocusEnabled = true
  var suppressesSceneStorage = false
  var storedPipelineStateRaw = ""
  var openEditor: @MainActor (PolicyCanvasEditSheet) -> Void = { _ in }
  var requestKeyboardFocus: @MainActor () -> Void = {}
  var persistViewportState: @MainActor (PolicyCanvasViewportObservedState, String?) -> Void =
    { _, _ in }
  var saveDraft: @MainActor () -> Void = {}
  var canSave = false
  var resizeZoomBehavior: PolicyCanvasViewportResizeZoomBehavior = .preserveZoom
  var minimapCenteringModeOverride: PolicyCanvasMinimapCenteringMode?
  var canvasColorSchemeOverride: ColorScheme?
  var showsEdgeLegend = true
  var showsQualityInspection = false
  @State private var zoomFocusDispatcher = PolicyCanvasZoomFocusDispatcher()
  @State private var layoutFocusDispatcher = PolicyCanvasLayoutFocusDispatcher()
  @State private var saveFocusDispatcher = PolicyCanvasSaveFocusDispatcher()
  @State private var commandFocus: PolicyCanvasCommandFocus?
  @State private var hasAppliedRestoredSceneZoom = false
  @State private var scrollApplicatorRequest: PolicyCanvasViewportScrollRequest?
  @State private var scrollApplicatorRequestID: UInt64 = 0
  @State private var routeCache = PolicyCanvasViewportRouteCache()
  @State private var validationWorker = PolicyCanvasValidationWorker()
  @State private var validationGeneration: UInt64 = 0
  /// Live scroll/zoom viewport rect, stored off-view so panning only refreshes
  /// the minimap overlay instead of rebuilding the full hosted canvas tree.
  @State private var viewportObservationStore = PolicyCanvasViewportObservationStore()
  @State private var handledSelectionFocusRequestID: UInt64?
  @AppStorage(PolicyCanvasMinimapDefaults.isVisibleKey)
  private var minimapVisible = PolicyCanvasMinimapDefaults.isVisibleDefault
  @AppStorage(PolicyCanvasHostThemeDefaults.modeKey)
  private var appThemeMode = PolicyCanvasHostThemeMode.auto
  @AppStorage(PolicyCanvasThemeDefaults.modeKey)
  private var canvasThemeMode = PolicyCanvasThemeMode.defaultValue
  @Environment(\.scenePhase)
  private var scenePhase
  @Environment(\.fontScale)
  private var fontScale

  private var resolvedCanvasColorScheme: ColorScheme? {
    canvasColorSchemeOverride ?? canvasThemeMode.resolvedColorScheme(appThemeMode: appThemeMode)
  }

  @MainActor
  func clearRouteCache(pipelineIdentity: String?) {
    routeCache.clear(pipelineIdentity: pipelineIdentity)
  }
  @MainActor
  func nextRouteGeneration() -> UInt64 {
    routeCache.nextGeneration()
  }
  @MainActor
  func routeGenerationMatches(_ generation: UInt64) -> Bool {
    routeCache.generationMatches(generation)
  }
  @MainActor
  func updateCachedRoutes(
    routeKey: PolicyCanvasRouteWorkerKey?,
    pipelineIdentity: String?,
    output: PolicyCanvasRouteWorkerOutput,
    nodePositionsByID: [String: CGPoint]
  ) {
    routeCache.update(
      routeKey: routeKey,
      pipelineIdentity: pipelineIdentity,
      output: output,
      nodePositionsByID: nodePositionsByID
    )
  }
  func routeWorkerInstance() -> PolicyCanvasRouteWorker { routeCache.worker }

  var body: some View {
    let routeCacheIdentity = viewModel.pipelineIdentity
    let routeCacheMatchesCanvas = routeCache.cachedCanvasIdentity == routeCacheIdentity
    let cachedOutput = routeCacheMatchesCanvas ? routeCache.cachedOutput : .empty
    let cachedNodePositionsByID =
      routeCacheMatchesCanvas ? routeCache.cachedNodePositionsByID : [:]
    let nodeValidationIssueMessagesByID = viewModel.nodeValidationIssueMessagesByID
    GeometryReader { proxy in
      let nodes = viewModel.nodes
      let groups = viewModel.groups
      let edges = viewModel.edges
      let routeKey = policyCanvasRouteWorkerKey(
        viewModel: viewModel,
        nodes: nodes,
        groups: groups,
        edges: edges,
        fontScale: fontScale
      )
      let routeKeyIsStale = routeCache.appliedRouteKey != routeKey
      let hasActivePositionDrag = viewModel.hasActivePositionDrag
      let routeProjectionSuppressed = hasActivePositionDrag || routeKeyIsStale
      let projectedRouteOutput = policyCanvasProjectedRouteOutput(
        input: PolicyCanvasProjectedRouteInput(
          cachedOutput: cachedOutput,
          cachedNodePositionsByID: cachedNodePositionsByID,
          currentNodes: nodes,
          groups: groups,
          edges: edges,
          fontScale: fontScale,
          suppressesProjection: routeProjectionSuppressed
        )
      )
      let routeOutputIsCurrentGraphMissing =
        !viewModel.isEmpty && projectedRouteOutput.signature == .empty
      let routeOutput = projectedRouteOutput
      let routeOutputNeedsRefresh =
        !hasActivePositionDrag && (routeOutputIsCurrentGraphMissing || routeKeyIsStale)
      let validationKey = policyCanvasValidationWorkerKey(
        viewModel: viewModel,
        nodes: nodes,
        groups: groups,
        edges: edges
      )
      let centeringRouteState = PolicyCanvasViewportCenteringRouteState(
        currentRouteKey: routeKey,
        appliedRouteKey: routeCache.appliedRouteKey,
        routeOutputSignature: routeOutput.signature,
        viewportCenteringGeneration: viewModel.viewportCenteringGeneration
      )
      let hostedSnapshot = policyCanvasViewportHostedSnapshot(
        input: PolicyCanvasViewportHostedSnapshotInput(
          viewModel: viewModel,
          focusedComponent: focusedComponent,
          edges: edges,
          routeOutput: routeOutput,
          nodeValidationIssueMessagesByID: nodeValidationIssueMessagesByID,
          resolvedCanvasColorScheme: resolvedCanvasColorScheme,
          showSimulationOverlay: showSimulationOverlay,
          openEditor: openEditor,
          requestKeyboardFocus: requestKeyboardFocus
        )
      )
      PolicyCanvasViewportHostedContent(
        viewModel: viewModel,
        snapshot: hostedSnapshot,
        zoom: viewModel.zoom,
        resizeZoomBehavior: resizeZoomBehavior,
        viewportIdentity: viewModel.pipelineIdentity,
        isActive: sceneFocusEnabled,
        isEmpty: viewModel.isEmpty,
        request: activeViewportScrollRequest(scrollApplicatorRequest),
        storedPipelineStateRaw: storedPipelineStateRaw,
        suppressesSceneStorage: suppressesSceneStorage,
        observationStore: viewportObservationStore,
        contentBounds: routeOutput.visibleBounds,
        minimapVisible: minimapVisible,
        showsQualityInspection: showsQualityInspection,
        resolvedCanvasColorScheme: resolvedCanvasColorScheme,
        minimapCenteringModeOverride: minimapCenteringModeOverride,
        showsEdgeLegend: showsEdgeLegend,
        onFulfillRequest: handleViewportScrollRequestFulfilled,
        onZoomChange: { zoom in
          guard abs(zoom - viewModel.zoom) > 0.001 else {
            return
          }
          viewModel.setZoom(zoom)
        },
        onViewportChange: { observedState, observedIdentity in
          guard
            observedIdentity != viewModel.pipelineIdentity
              || !viewModel.hasPendingViewportCenteringRequest
          else {
            return
          }
          if observedIdentity == viewModel.pipelineIdentity {
            let matchesRestoredMinimapViewport =
              policyCanvasMinimapViewportMatchesRestoredSceneState(
                observedState: observedState,
                identity: observedIdentity,
                storedPipelineStateRaw: storedPipelineStateRaw,
                suppressesSceneStorage: suppressesSceneStorage
              )
            if !matchesRestoredMinimapViewport {
              viewportObservationStore.update(observedState, for: observedIdentity)
            }
          }
          persistViewportState(observedState, observedIdentity)
        },
        requestViewportScroll: { requestViewportScroll(target: .contentOrigin($0)) }
      )
      .onAppear {
        centerViewportIfNeeded(
          viewportSize: proxy.size,
          routeOutput: routeOutput,
          currentRouteKey: routeKey,
          routeOutputIsCurrentGraphProvisional: routeOutputIsCurrentGraphMissing
        )
        focusSelectionIfNeeded(
          request: selectionFocusRequest,
          routeOutput: routeOutput
        )
        bindCommandFocus()
      }
      .onChange(of: centeringRouteState, initial: false) {
        centerViewportIfNeeded(
          viewportSize: proxy.size,
          routeOutput: routeOutput,
          currentRouteKey: routeKey,
          routeOutputIsCurrentGraphProvisional: routeOutputIsCurrentGraphMissing
        )
      }
      .onChange(of: routeOutput.signature, initial: false) {
        focusSelectionIfNeeded(
          request: selectionFocusRequest,
          routeOutput: routeOutput
        )
      }
      .task(id: selectionFocusRequest?.id) {
        focusSelectionIfNeeded(
          request: selectionFocusRequest,
          routeOutput: routeOutput
        )
      }
      .task(
        id: PolicyCanvasViewportRouteRefreshKey(
          routeKey: routeKey,
          pipelineIdentity: routeCacheIdentity,
          needsRefresh: routeOutputNeedsRefresh
        )
      ) {
        guard routeOutputNeedsRefresh else { return }
        await rebuildRoutes(
          for: routeKey,
          pipelineIdentity: routeCacheIdentity,
          fontScale: fontScale
        )
      }
      .onChange(of: scenePhase) { _, newPhase in
        if newPhase != ScenePhase.active {
          viewModel.clearPinchAnchor()
        }
      }

      .onChange(of: viewModel.canReflowLayout, initial: false) {
        bindCommandFocus()
      }
      .onChange(of: viewModel.pipelineIdentity, initial: false) { _, newIdentity in
        if let newIdentity, let cachedRouteOutput = routeCache.outputsByCanvasIdentity[newIdentity]
        {
          routeCache.appliedRouteKey = routeKey
          routeCache.cachedOutput = cachedRouteOutput.output
          routeCache.cachedNodePositionsByID = cachedRouteOutput.nodePositionsByID
          routeCache.cachedCanvasIdentity = newIdentity
        } else {
          clearCachedRouteOutput()
        }
        hasAppliedRestoredSceneZoom = false
      }
      .onChange(of: viewModel.routeComputationRequestGeneration, initial: false) {
        guard
          viewModel.routeComputationRequestGeneration > 0,
          !viewModel.hasActivePositionDrag
        else {
          return
        }
        Task { @MainActor in
          await rebuildRoutes(
            for: routeKey,
            pipelineIdentity: routeCacheIdentity,
            fontScale: fontScale
          )
        }
      }
      .onChange(of: viewModel.atomicReflowRequest?.id, initial: false) {
        Task { @MainActor in
          await performAtomicReflow(fontScale: fontScale)
        }
      }
      .harnessFocusedSceneValue(
        \.harnessPolicyCanvasCommandFocus,
        sceneFocusEnabled ? commandFocus : nil
      )
      .task(id: validationKey) {
        await rebuildValidation()
      }
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.policyCanvasViewport)
  }
}

extension PolicyCanvasViewport {
  @MainActor
  private func bindCommandFocus() {
    bindZoomFocusDispatcher()
    bindLayoutFocusDispatcher()
    bindSaveFocusDispatcher()
    let nextFocus = policyCanvasCommandFocus(
      zoomFocusDispatcher: zoomFocusDispatcher,
      canReflow: viewModel.canReflowLayout,
      layoutFocusDispatcher: layoutFocusDispatcher,
      canSave: canSave,
      saveFocusDispatcher: saveFocusDispatcher
    )
    guard commandFocus != nextFocus else {
      return
    }
    commandFocus = nextFocus
  }
  private func centerViewportIfNeeded(
    viewportSize: CGSize,
    routeOutput: PolicyCanvasRouteWorkerOutput,
    currentRouteKey: PolicyCanvasRouteWorkerKey,
    routeOutputIsCurrentGraphProvisional: Bool = false
  ) {
    guard
      let plan = policyCanvasViewportCenteringPlan(
        input: PolicyCanvasViewportCenteringPlanInput(
          viewModel: viewModel,
          viewportSize: viewportSize,
          routeOutput: routeOutput,
          currentRouteKey: currentRouteKey,
          appliedRouteKey: routeCache.appliedRouteKey,
          routeOutputIsCurrentGraphProvisional: routeOutputIsCurrentGraphProvisional,
          storedPipelineStateRaw: storedPipelineStateRaw,
          suppressesSceneStorage: suppressesSceneStorage,
          hasAppliedRestoredSceneZoom: hasAppliedRestoredSceneZoom
        )
      )
    else {
      return
    }
    if let targetZoom = plan.targetZoom, abs(targetZoom - viewModel.zoom) > 0.001 {
      viewModel.setZoom(targetZoom)
    }
    hasAppliedRestoredSceneZoom = plan.appliedRestoredSceneZoom
    let viewportCenteringGeneration = viewModel.viewportCenteringGeneration
    if plan.defersScrollUntilNextRunloop {
      Task { @MainActor in
        await Task.yield()
        await Task.yield()
        guard
          viewModel.viewportCenteringGeneration == viewportCenteringGeneration,
          viewModel.hasPendingViewportCenteringRequest
        else {
          return
        }
        requestViewportScroll(
          target: .centeredDocumentAnchor(plan.anchorPoint),
          viewportCenteringGenerationToConsume: viewportCenteringGeneration
        )
      }
      return
    }
    requestViewportScroll(
      target: .contentOrigin(plan.anchorPoint),
      viewportCenteringGenerationToConsume: viewportCenteringGeneration
    )
  }
  private func focusSelectionIfNeeded(
    request: PolicyCanvasViewportSelectionFocusRequest?,
    routeOutput: PolicyCanvasRouteWorkerOutput
  ) {
    guard
      let plan = policyCanvasViewportSelectionFocusPlan(
        request: request,
        handledRequestID: handledSelectionFocusRequestID,
        viewModel: viewModel,
        routeOutput: routeOutput
      )
    else {
      return
    }
    handledSelectionFocusRequestID = plan.handledRequestID
    Task { @MainActor in
      await Task.yield()
      await Task.yield()
      requestViewportScroll(target: .centeredDocumentAnchor(plan.anchorPoint))
    }
  }
  private func bindZoomFocusDispatcher() {
    zoomFocusDispatcher = policyCanvasZoomFocusDispatcher(viewModel: viewModel)
  }
  private func bindLayoutFocusDispatcher() {
    layoutFocusDispatcher = policyCanvasLayoutFocusDispatcher(viewModel: viewModel)
  }
  private func bindSaveFocusDispatcher() {
    saveFocusDispatcher = policyCanvasSaveFocusDispatcher(saveDraft: saveDraft)
  }
  @MainActor
  private func rebuildValidation() async {
    validationGeneration &+= 1
    let generation = validationGeneration
    let output = await policyCanvasViewportValidationPresentation(
      worker: validationWorker,
      viewModel: viewModel
    )
    guard !Task.isCancelled, validationGeneration == generation else {
      return
    }
    viewModel.applyValidationPresentation(output)
  }
  private func requestViewportScroll(
    target: PolicyCanvasViewportScrollTarget,
    viewportCenteringGenerationToConsume: UInt64? = nil
  ) {
    scrollApplicatorRequestID &+= 1
    scrollApplicatorRequest = PolicyCanvasViewportScrollRequest(
      id: scrollApplicatorRequestID,
      target: target,
      viewportCenteringGenerationToConsume: viewportCenteringGenerationToConsume
    )
  }
  private func activeViewportScrollRequest(
    _ request: PolicyCanvasViewportScrollRequest?
  ) -> PolicyCanvasViewportScrollRequest? {
    guard
      let request,
      let viewportCenteringGeneration = request.viewportCenteringGenerationToConsume
    else {
      return request
    }
    guard
      viewportCenteringGeneration == viewModel.viewportCenteringGeneration,
      viewModel.hasPendingViewportCenteringRequest
    else {
      return nil
    }
    return request
  }
  private func handleViewportScrollRequestFulfilled(
    _ request: PolicyCanvasViewportScrollRequest,
    appliesScroll: Bool
  ) {
    guard scrollApplicatorRequest?.id == request.id else {
      return
    }
    if let viewportCenteringGeneration = request.viewportCenteringGenerationToConsume {
      _ = viewModel.consumeViewportCenteringRequest(generation: viewportCenteringGeneration)
    }
    _ = appliesScroll
  }
}
