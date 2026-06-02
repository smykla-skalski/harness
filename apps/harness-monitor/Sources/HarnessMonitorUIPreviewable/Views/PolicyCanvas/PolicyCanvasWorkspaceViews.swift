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
  @State private var zoomFocusDispatcher = PolicyCanvasZoomFocusDispatcher()
  @State private var layoutFocusDispatcher = PolicyCanvasLayoutFocusDispatcher()
  @State private var saveFocusDispatcher = PolicyCanvasSaveFocusDispatcher()
  @State private var commandFocus: PolicyCanvasCommandFocus?
  @State private var hasAppliedRestoredSceneZoom = false
  @State private var scrollApplicatorRequest: PolicyCanvasViewportScrollRequest?
  @State private var scrollApplicatorRequestID: UInt64 = 0
  @State private var routeWorker = PolicyCanvasRouteWorker()
  @State private var routeGeneration: UInt64 = 0
  @State private var appliedRouteKey: PolicyCanvasRouteWorkerKey?
  @State private var validationWorker = PolicyCanvasValidationWorker()
  @State private var validationGeneration: UInt64 = 0
  @State private var cachedRouteOutput = PolicyCanvasRouteWorkerOutput.empty
  @State private var cachedRouteNodePositionsByID: [String: CGPoint] = [:]
  @State private var cachedRouteCanvasIdentity: String?
  /// Live scroll/zoom viewport rect, stored off-view so panning only refreshes
  /// the minimap overlay instead of rebuilding the full hosted canvas tree.
  @State private var viewportObservationStore = PolicyCanvasViewportObservationStore()
  @State private var handledSelectionFocusRequestID: UInt64?
  @AppStorage(PolicyCanvasMinimapDefaults.isVisibleKey)
  private var minimapVisible = PolicyCanvasMinimapDefaults.isVisibleDefault
  @AppStorage(HarnessMonitorThemeDefaults.modeKey)
  private var appThemeMode = HarnessMonitorThemeMode.auto
  @AppStorage(PolicyCanvasThemeDefaults.modeKey)
  private var canvasThemeMode = PolicyCanvasThemeMode.defaultValue
  @Environment(\.scenePhase)
  private var scenePhase
  @Environment(\.fontScale)
  private var fontScale

  private var resolvedCanvasColorScheme: ColorScheme? {
    canvasThemeMode.resolvedColorScheme(appThemeMode: appThemeMode)
  }

  var body: some View {
    let routeCacheIdentity = viewModel.pipelineIdentity
    let routeCacheMatchesCanvas = cachedRouteCanvasIdentity == routeCacheIdentity
    let cachedOutput = routeCacheMatchesCanvas ? cachedRouteOutput : .empty
    let cachedNodePositionsByID = routeCacheMatchesCanvas ? cachedRouteNodePositionsByID : [:]
    let nodeValidationIssueMessagesByID = viewModel.nodeValidationIssueMessagesByID
    GeometryReader { proxy in
      let nodes = viewModel.nodes
      let groups = viewModel.groups
      let edges = viewModel.edges
      let routeInput = PolicyCanvasRouteWorkerInput(
        graphGeneration: viewModel.routeComputationGeneration,
        nodes: nodes,
        groups: groups,
        edges: edges,
        fontScale: fontScale,
        routingHints: viewModel.routingHints,
        algorithmSelection: viewModel.algorithmSelection
      )
      let routeKey = policyCanvasRouteWorkerKey(
        viewModel: viewModel,
        nodes: nodes,
        groups: groups,
        edges: edges,
        fontScale: fontScale
      )
      let projectedRouteOutput = policyCanvasProjectedRouteOutput(
        input: PolicyCanvasProjectedRouteInput(
          cachedOutput: cachedOutput,
          cachedNodePositionsByID: cachedNodePositionsByID,
          currentNodes: nodes,
          groups: groups,
          edges: edges,
          fontScale: fontScale
        )
      )
      let routeOutputIsCurrentGraphProvisional =
        !viewModel.isEmpty && projectedRouteOutput.signature == .empty
      let routeOutput =
        routeOutputIsCurrentGraphProvisional
        ? PolicyCanvasRouteWorkerOutput.fallback(for: routeInput)
        : projectedRouteOutput
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
      PolicyCanvasViewportNativeHost(
        snapshot: hostedSnapshot,
        zoom: viewModel.zoom,
        viewportIdentity: viewModel.pipelineIdentity,
        isActive: sceneFocusEnabled,
        isEmpty: viewModel.isEmpty,
        request: scrollApplicatorRequest,
        onFulfillRequest: handleViewportScrollRequestFulfilled,
        onZoomChange: { zoom in
          guard abs(zoom - viewModel.zoom) > 0.001 else {
            return
          }
          viewModel.setZoom(zoom)
        },
        onViewportChange: { observedState, observedIdentity in
          guard observedIdentity != viewModel.pipelineIdentity
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
        }
      )
      .clipShape(Rectangle())
      // The canvas pans horizontally, so a two-finger horizontal scroll over
      // this viewport belongs to the canvas, not to history navigation.
      .harnessTrackpadSwipeOptOut()
      .overlay {
        PolicyCanvasEmptyStatePlaceholder(viewModel: viewModel)
          .policyCanvasResolvedThemeScope(resolvedCanvasColorScheme)
          .allowsHitTesting(false)
      }
      .modifier(
        PolicyCanvasViewportOverlayModifier(
          viewModel: viewModel,
          observationStore: viewportObservationStore,
          storedPipelineStateRaw: storedPipelineStateRaw,
          suppressesSceneStorage: suppressesSceneStorage,
          contentBounds: routeOutput.visibleBounds,
          minimapVisible: minimapVisible,
          resolvedCanvasColorScheme: resolvedCanvasColorScheme,
          requestViewportScroll: { requestViewportScroll(to: $0) }
        )
      )
      .onAppear {
        centerViewportIfNeeded(
          viewportSize: proxy.size,
          routeOutput: routeOutput,
          currentRouteKey: routeKey,
          routeOutputIsCurrentGraphProvisional: routeOutputIsCurrentGraphProvisional
        )
        focusSelectionIfNeeded(
          request: selectionFocusRequest,
          viewportSize: proxy.size,
          routeOutput: routeOutput
        )
        bindCommandFocus()
      }
      .onChange(of: centeringRouteState, initial: false) {
        centerViewportIfNeeded(
          viewportSize: proxy.size,
          routeOutput: routeOutput,
          currentRouteKey: routeKey,
          routeOutputIsCurrentGraphProvisional: routeOutputIsCurrentGraphProvisional
        )
      }
      .onChange(of: routeOutput.signature, initial: false) {
        focusSelectionIfNeeded(
          request: selectionFocusRequest,
          viewportSize: proxy.size,
          routeOutput: routeOutput
        )
      }
      .task(id: selectionFocusRequest?.id) {
        focusSelectionIfNeeded(
          request: selectionFocusRequest,
          viewportSize: proxy.size,
          routeOutput: routeOutput
        )
      }
      .onChange(of: scenePhase) { _, newPhase in
        if newPhase != .active {
          viewModel.clearPinchAnchor()
        }
      }

      .onChange(of: viewModel.canReflowLayout, initial: false) {
        bindCommandFocus()
      }
      .onChange(of: viewModel.pipelineIdentity, initial: false) {
        clearCachedRouteOutput()
        hasAppliedRestoredSceneZoom = false
      }
      .onChange(of: viewModel.routeComputationRequestGeneration, initial: false) {
        guard viewModel.routeComputationRequestGeneration > 0 else {
          return
        }
        Task { @MainActor in
          await rebuildRoutes(for: routeKey, pipelineIdentity: routeCacheIdentity)
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
    let nextFocus = PolicyCanvasCommandFocus(
      zoom: PolicyCanvasZoomFocus(dispatcher: zoomFocusDispatcher),
      layout: PolicyCanvasLayoutFocus(
        canReflow: viewModel.canReflowLayout,
        dispatcher: layoutFocusDispatcher
      ),
      save: PolicyCanvasSaveFocus(
        canSave: canSave,
        dispatcher: saveFocusDispatcher
      )
    )
    guard commandFocus != nextFocus else {
      return
    }
    commandFocus = nextFocus
  }

  @MainActor
  private func clearCachedRouteOutput() {
    appliedRouteKey = nil
    cachedRouteOutput = .empty
    cachedRouteNodePositionsByID = [:]
    cachedRouteCanvasIdentity = viewModel.pipelineIdentity
  }

  @MainActor
  private func rebuildRoutes(
    for routeKey: PolicyCanvasRouteWorkerKey,
    pipelineIdentity: String?
  ) async {
    routeGeneration &+= 1
    let generation = routeGeneration
    let input = PolicyCanvasRouteWorkerInput(
      graphGeneration: viewModel.routeComputationGeneration,
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: fontScale,
      routingHints: viewModel.routingHints,
      algorithmSelection: viewModel.algorithmSelection
    )
    let output = await routeWorker.compute(input: input)
    guard !Task.isCancelled, routeGeneration == generation else {
      return
    }
    cachedRouteCanvasIdentity = pipelineIdentity
    cachedRouteNodePositionsByID = policyCanvasNodePositionsByID(input.nodes)
    if cachedRouteOutput.signature != output.signature {
      cachedRouteOutput = output
    }
    appliedRouteKey = routeKey
  }

  private func policyCanvasMinimapViewportMatchesRestoredSceneState(
    observedState: PolicyCanvasViewportObservedState,
    identity: String?,
    storedPipelineStateRaw: String,
    suppressesSceneStorage: Bool
  ) -> Bool {
    guard
      let restoredViewportRect = PolicyCanvasView.sceneState(
        for: identity,
        raw: storedPipelineStateRaw,
        suppressesSceneStorage: suppressesSceneStorage
      )?
      .viewportRect
    else {
      return false
    }
    return policyCanvasMinimapViewportRectApproximatelyMatches(
      observedState.visibleContentRect,
      restoredViewportRect
    )
  }

  private func policyCanvasMinimapViewportRectApproximatelyMatches(
    _ lhs: CGRect,
    _ rhs: CGRect
  ) -> Bool {
    abs(lhs.minX - rhs.minX) < 0.5
      && abs(lhs.minY - rhs.minY) < 0.5
      && abs(lhs.width - rhs.width) < 0.5
      && abs(lhs.height - rhs.height) < 0.5
  }

  @MainActor
  private func rebuildValidation() async {
    validationGeneration &+= 1
    let generation = validationGeneration
    let input = PolicyCanvasValidationWorkerInput(
      nodes: viewModel.nodes,
      edges: viewModel.edges,
      daemonIssues: viewModel.daemonValidationIssues
    )
    let output = await validationWorker.compute(input: input)
    guard !Task.isCancelled, validationGeneration == generation else {
      return
    }
    viewModel.applyValidationPresentation(output)
  }

  private func centerViewportIfNeeded(
    viewportSize: CGSize,
    routeOutput: PolicyCanvasRouteWorkerOutput,
    currentRouteKey: PolicyCanvasRouteWorkerKey,
    routeOutputIsCurrentGraphProvisional: Bool = false
  ) {
    guard
      viewModel.hasPendingViewportCenteringRequest,
      policyCanvasCanCenterViewport(
        isCanvasEmpty: viewModel.isEmpty,
        routeOutputSignature: routeOutput.signature,
        currentRouteKey: currentRouteKey,
        appliedRouteKey: appliedRouteKey,
        routeOutputIsCurrentGraphProvisional: routeOutputIsCurrentGraphProvisional,
        allowsProvisionalRouteOutput:
          viewModel.viewportCenteringBehavior.allowsProvisionalRouteOutput
      )
    else {
      return
    }
    let visibleBounds = routeOutput.visibleBounds
    let restoredSceneState = PolicyCanvasView.sceneState(
      for: viewModel.pipelineIdentity,
      raw: storedPipelineStateRaw,
      suppressesSceneStorage: suppressesSceneStorage
    )
    var targetZoom = viewModel.zoom
    if let restoredSceneState, !hasAppliedRestoredSceneZoom {
      let restoredZoom = PolicyCanvasViewModel.sanitizedZoom(
        CGFloat(restoredSceneState.zoom),
        fallback: viewModel.zoom
      )
      if abs(restoredZoom - viewModel.zoom) > 0.001 {
        viewModel.setZoom(restoredZoom)
      }
      targetZoom = restoredZoom
      hasAppliedRestoredSceneZoom = true
    } else if restoredSceneState == nil {
      let fittedZoom = viewModel.fittedInitialZoom(
        for: viewportSize,
        contentBounds: visibleBounds
      )
      targetZoom = viewModel.isEmpty ? viewModel.zoom : min(viewModel.zoom, fittedZoom)
      if abs(targetZoom - viewModel.zoom) > 0.001 {
        viewModel.setZoom(targetZoom)
      }
    }
    if let restoredViewportOrigin = restoredSceneState?.viewportOrigin {
      requestViewportScroll(to: restoredViewportOrigin, consumesViewportCenteringRequest: true)
      return
    }
    Task { @MainActor in
      await Task.yield()
      await Task.yield()
      let selectionScrollPoint =
        policyCanvasViewportCenteringSelectionScrollPoint(
          behavior: viewModel.viewportCenteringBehavior,
          selection: viewModel.selection,
          viewModel: viewModel,
          routeOutput: routeOutput,
          viewportSize: viewportSize,
          zoom: targetZoom
        )
      requestViewportScroll(
        to: selectionScrollPoint
          ?? policyCanvasInitialViewportDocumentScrollPoint(
            visibleBounds: visibleBounds,
            viewportSize: viewportSize,
            zoom: targetZoom
          ),
        consumesViewportCenteringRequest: true
      )
    }
  }

  private func focusSelectionIfNeeded(
    request: PolicyCanvasViewportSelectionFocusRequest?,
    viewportSize: CGSize,
    routeOutput: PolicyCanvasRouteWorkerOutput
  ) {
    guard let request, handledSelectionFocusRequestID != request.id else {
      return
    }
    guard
      let scrollPoint = policyCanvasSelectionViewportDocumentScrollPoint(
        selection: request.selection,
        viewModel: viewModel,
        routeOutput: routeOutput,
        viewportSize: viewportSize,
        zoom: viewModel.zoom
      )
    else {
      return
    }
    handledSelectionFocusRequestID = request.id
    Task { @MainActor in
      await Task.yield()
      await Task.yield()
      requestViewportScroll(to: scrollPoint)
    }
  }

  private func bindZoomFocusDispatcher() {
    zoomFocusDispatcher.zoomIn = { @MainActor [viewModel] in
      viewModel.clearPinchAnchor()
      viewModel.zoomIn()
    }
    zoomFocusDispatcher.zoomOut = { @MainActor [viewModel] in
      viewModel.clearPinchAnchor()
      viewModel.zoomOut()
    }
    zoomFocusDispatcher.resetZoom = { @MainActor [viewModel] in
      viewModel.clearPinchAnchor()
      viewModel.resetZoom()
    }
  }

  private func bindLayoutFocusDispatcher() {
    layoutFocusDispatcher.reflowLayout = { @MainActor [viewModel] in
      viewModel.reflowLayout(preserveManualAnchors: false, force: true)
    }
  }

  private func bindSaveFocusDispatcher() {
    saveFocusDispatcher.save = { @MainActor [saveDraft] in
      saveDraft()
    }
  }

  private func requestViewportScroll(
    to point: CGPoint,
    consumesViewportCenteringRequest: Bool = false
  ) {
    scrollApplicatorRequestID &+= 1
    scrollApplicatorRequest = PolicyCanvasViewportScrollRequest(
      id: scrollApplicatorRequestID,
      point: point,
      consumesViewportCenteringRequest: consumesViewportCenteringRequest
    )
  }

  private func handleViewportScrollRequestFulfilled(
    _ request: PolicyCanvasViewportScrollRequest,
    appliesScroll: Bool
  ) {
    guard scrollApplicatorRequest?.id == request.id else {
      return
    }
    if request.consumesViewportCenteringRequest {
      _ = viewModel.consumeViewportCenteringRequest()
    }
    _ = appliesScroll
  }
}
