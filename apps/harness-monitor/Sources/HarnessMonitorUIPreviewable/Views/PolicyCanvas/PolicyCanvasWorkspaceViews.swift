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
  var isInspectorVisible = false
  var canToggleInspector = false
  var toggleInspector: @MainActor () -> Void = {}
  var resizeZoomBehavior: PolicyCanvasViewportResizeZoomBehavior = .preserveZoom
  var minimapCenteringModeOverride: PolicyCanvasMinimapCenteringMode?
  var canvasColorSchemeOverride: ColorScheme?
  var showsEdgeLegend = true
  var showsQualityInspection = false
  var routeSeed: PolicyCanvasViewportRouteSeed?
  var onFinalRouteOutputReady: @MainActor () -> Void = {}
  @State private var zoomFocusDispatcher = PolicyCanvasZoomFocusDispatcher()
  @State private var layoutFocusDispatcher = PolicyCanvasLayoutFocusDispatcher()
  @State private var saveFocusDispatcher = PolicyCanvasSaveFocusDispatcher()
  @State private var inspectorFocusDispatcher = PolicyCanvasInspectorFocusDispatcher()
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

  // Internal bridge accessors so companion-file extensions can read/write @State private storage.
  var bridgeHasAppliedRestoredSceneZoom: Bool {
    get { hasAppliedRestoredSceneZoom }
    nonmutating set { hasAppliedRestoredSceneZoom = newValue }
  }
  var bridgeScrollApplicatorRequest: PolicyCanvasViewportScrollRequest? {
    get { scrollApplicatorRequest }
    nonmutating set { scrollApplicatorRequest = newValue }
  }
  var bridgeScrollApplicatorRequestID: UInt64 {
    get { scrollApplicatorRequestID }
    nonmutating set { scrollApplicatorRequestID = newValue }
  }
  var bridgeRouteCache: PolicyCanvasViewportRouteCache {
    get { routeCache }
    nonmutating set { routeCache = newValue }
  }
  var bridgeValidationWorker: PolicyCanvasValidationWorker {
    validationWorker
  }
  var bridgeValidationGeneration: UInt64 {
    get { validationGeneration }
    nonmutating set { validationGeneration = newValue }
  }
  var bridgeHandledSelectionFocusRequestID: UInt64? {
    get { handledSelectionFocusRequestID }
    nonmutating set { handledSelectionFocusRequestID = newValue }
  }
  var bridgeCommandFocus: PolicyCanvasCommandFocus? {
    get { commandFocus }
    nonmutating set { commandFocus = newValue }
  }
  var bridgeZoomFocusDispatcher: PolicyCanvasZoomFocusDispatcher {
    get { zoomFocusDispatcher }
    nonmutating set { zoomFocusDispatcher = newValue }
  }
  var bridgeLayoutFocusDispatcher: PolicyCanvasLayoutFocusDispatcher {
    get { layoutFocusDispatcher }
    nonmutating set { layoutFocusDispatcher = newValue }
  }
  var bridgeSaveFocusDispatcher: PolicyCanvasSaveFocusDispatcher {
    get { saveFocusDispatcher }
    nonmutating set { saveFocusDispatcher = newValue }
  }
  var bridgeInspectorFocusDispatcher: PolicyCanvasInspectorFocusDispatcher {
    get { inspectorFocusDispatcher }
    nonmutating set { inspectorFocusDispatcher = newValue }
  }

  var body: some View {
    let routeCacheIdentity = viewModel.pipelineIdentity
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
      let resolvedRouteCache = policyCanvasViewportResolvedRouteCache(
        routeCache: routeCache,
        routeKey: routeKey,
        pipelineIdentity: routeCacheIdentity,
        routeSeed: routeSeed
      )
      let cachedOutput = resolvedRouteCache.output
      let cachedNodePositionsByID = resolvedRouteCache.nodePositionsByID
      let appliedRouteKey = resolvedRouteCache.appliedRouteKey
      let routeKeyIsStale = appliedRouteKey != routeKey
      let hasActivePositionDrag = viewModel.hasActivePositionDrag
      let projectedRouteResult = policyCanvasProjectedRouteResult(
        input: PolicyCanvasProjectedRouteInput(
          cachedOutput: cachedOutput,
          cachedNodePositionsByID: cachedNodePositionsByID,
          currentNodes: nodes,
          groups: groups,
          edges: edges,
          fontScale: fontScale
        )
      )
      let routeProjectionCanCommit =
        routeKeyIsStale && projectedRouteResult.canCommitAsCurrentGraph
      let routeOutputIsCurrentGraphMissing =
        !viewModel.isEmpty && projectedRouteResult.output.signature == .empty
      let routeOutput = projectedRouteResult.output
      let routeOutputMatchesCurrentGraph =
        !viewModel.isEmpty
        && projectedRouteResult.matchesCurrentGraphShape
        && routeOutput.signature != .empty
      let finalRouteOutputReady =
        !viewModel.isEmpty && !routeKeyIsStale && routeOutput.signature != .empty
      let hasRenderableRouteOutput =
        viewModel.isEmpty || finalRouteOutputReady
        || (routeKeyIsStale && routeOutputMatchesCurrentGraph)
      let routeOutputNeedsRefresh =
        !hasActivePositionDrag
        && (routeOutputIsCurrentGraphMissing || (routeKeyIsStale && !routeProjectionCanCommit))
      let validationKey = policyCanvasValidationWorkerKey(
        viewModel: viewModel,
        nodes: nodes,
        groups: groups,
        edges: edges
      )
      let centeringRouteState = PolicyCanvasViewportCenteringRouteState(
        currentRouteKey: routeKey,
        appliedRouteKey: appliedRouteKey,
        routeOutputSignature: routeOutput.signature,
        routeOutputMatchesCurrentGraph: routeOutputMatchesCurrentGraph,
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
          hasRenderableRouteOutput: hasRenderableRouteOutput,
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
        focusSelectionIfNeeded(
          request: selectionFocusRequest,
          routeOutput: routeOutput
        )
        bindCommandFocus()
      }
      .task(id: centeringRouteState) {
        await centerViewportAfterRouteStateSettles(
          viewportSize: proxy.size,
          routeOutput: routeOutput,
          currentRouteKey: routeKey,
          routeOutputMatchesCurrentGraph: routeOutputMatchesCurrentGraph
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
      .task(
        id: PolicyCanvasViewportRouteProjectionCommitKey(
          routeKey: routeKey,
          pipelineIdentity: routeCacheIdentity,
          outputSignature: routeOutput.signature,
          canCommit: routeProjectionCanCommit
        )
      ) {
        guard routeProjectionCanCommit else { return }
        updateCachedRoutes(
          routeKey: routeKey,
          pipelineIdentity: routeCacheIdentity,
          output: routeOutput,
          nodePositionsByID: policyCanvasNodePositionsByID(nodes)
        )
      }
      .task(id: routeSeed?.id) {
        guard
          let routeSeed,
          routeSeed.routeKey == routeKey,
          routeSeed.pipelineIdentity == routeCacheIdentity
        else {
          return
        }
        updateCachedRoutes(
          routeKey: routeSeed.routeKey,
          pipelineIdentity: routeSeed.pipelineIdentity,
          output: routeSeed.output,
          nodePositionsByID: routeSeed.nodePositionsByID
        )
      }
      .task(id: finalRouteOutputReady) {
        guard finalRouteOutputReady else {
          return
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled else {
          return
        }
        onFinalRouteOutputReady()
      }
      .onChange(of: scenePhase) { _, newPhase in
        if newPhase != ScenePhase.active {
          viewModel.clearPinchAnchor()
        }
      }

      .onChange(of: viewModel.canReflowLayout, initial: false) {
        bindCommandFocus()
      }
      .onChange(of: isInspectorVisible, initial: false) {
        bindCommandFocus()
      }
      .onChange(of: canToggleInspector, initial: false) {
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
