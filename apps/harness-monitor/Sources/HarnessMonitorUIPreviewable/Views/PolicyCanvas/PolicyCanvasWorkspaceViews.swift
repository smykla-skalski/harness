import SwiftUI

struct PolicyCanvasViewportSelectionFocusRequest: Equatable {
  let id: UInt64
  let selection: PolicyCanvasSelection
}

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
  @State private var zoomFocusDispatcher = PolicyCanvasZoomFocusDispatcher()
  @State private var layoutFocusDispatcher = PolicyCanvasLayoutFocusDispatcher()
  @State private var commandFocus: PolicyCanvasCommandFocus?
  @State private var hasAppliedRestoredSceneZoom = false
  @State private var scrollApplicatorRequest: PolicyCanvasViewportScrollRequest?
  @State private var scrollApplicatorRequestID: UInt64 = 0
  @State private var routeWorker = PolicyCanvasRouteWorker()
  @State private var routeGeneration: UInt64 = 0
  @State private var validationWorker = PolicyCanvasValidationWorker()
  @State private var validationGeneration: UInt64 = 0
  @State private var cachedRouteOutput = PolicyCanvasRouteWorkerOutput.empty
  @State private var viewportObservation: PolicyCanvasViewportObservedState?
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
    let routeOutput = cachedRouteOutput
    let routes = routeOutput.routes
    let labelPositions = routeOutput.labelPositions
    let portVisibility = routeOutput.portVisibility
    let portMarkerLayout = routeOutput.portMarkerLayout
    let accessibilityLabelsByEdgeID = routeOutput.accessibilityEdgeLabelsByID
    let accessibilityNodeEntries = routeOutput.accessibilityNodeEntries
    let accessibilityEdgeEntries = routeOutput.accessibilityEdgeEntries
    let nodeAccessibilityValuesByID = routeOutput.nodeAccessibilityValuesByID
    let connectTargetsByNodeID = routeOutput.connectTargetsByNodeID
    let nodeValidationIssueMessagesByID = viewModel.nodeValidationIssueMessagesByID
    let contentSize = routeOutput.contentSize
    let nodeFrames = viewModel.nodes.map {
      CGRect(origin: $0.position, size: PolicyCanvasLayout.nodeSize)
    }
    let minimapSnapshot = policyCanvasMinimapSnapshot(
      contentBounds: routeOutput.visibleBounds,
      viewportRect: viewportObservation?.visibleContentRect ?? routeOutput.visibleBounds,
      nodeFrames: nodeFrames,
      groupFrames: viewModel.groups.map(\.frame)
    )
    GeometryReader { proxy in
      let edges = viewModel.edges
      let routeKey = PolicyCanvasRouteWorkerKey(
        graphGeneration: viewModel.routeComputationGeneration,
        nodeCount: viewModel.nodes.count,
        groupCount: viewModel.groups.count,
        edgeCount: edges.count,
        fontScale: fontScale,
        routingHints: viewModel.routingHints
      )
      let validationKey = PolicyCanvasValidationWorkerKey(
        graphGeneration: viewModel.routeComputationGeneration,
        nodeCount: viewModel.nodes.count,
        edgeCount: edges.count,
        groupCount: viewModel.groups.count,
        simulationRevision: viewModel.latestSimulation?.revision,
        simulationIssueCount: viewModel.latestSimulation?.validation.issues.count ?? 0,
        simulationValid: viewModel.latestSimulation?.validation.isValid ?? true
      )
      let hostedSnapshot = PolicyCanvasViewportHostedSnapshot(
        viewModel: viewModel,
        focusedComponent: focusedComponent,
        edges: edges,
        routes: routes,
        labelPositions: labelPositions,
        accessibilityLabelsByEdgeID: accessibilityLabelsByEdgeID,
        accessibilityNodeEntries: accessibilityNodeEntries,
        accessibilityEdgeEntries: accessibilityEdgeEntries,
        nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
        connectTargetsByNodeID: connectTargetsByNodeID,
        nodeValidationIssueMessagesByID: nodeValidationIssueMessagesByID,
        portVisibility: portVisibility,
        portMarkerLayout: portMarkerLayout,
        contentSize: contentSize,
        resolvedCanvasColorScheme: resolvedCanvasColorScheme,
        showSimulationOverlay: showSimulationOverlay,
        openEditor: openEditor,
        requestKeyboardFocus: requestKeyboardFocus
      )
      PolicyCanvasViewportNativeHost(
        snapshot: hostedSnapshot,
        zoom: viewModel.zoom,
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
        onViewportChange: { observedState in
          viewportObservation = observedState
        }
      )
      .background(PolicyCanvasVisualStyle.canvasBackground)
      .clipShape(Rectangle())
      // The canvas pans horizontally, so a two-finger horizontal scroll over
      // this viewport belongs to the canvas, not to history navigation.
      .harnessTrackpadSwipeOptOut()
      .overlay {
        PolicyCanvasEmptyStatePlaceholder(viewModel: viewModel)
          .allowsHitTesting(false)
      }
      .overlay(alignment: .topLeading) {
        PolicyCanvasEdgeKindLegend()
          .padding(14)
      }
      .overlay(alignment: .bottomLeading) {
        PolicyCanvasZoomControls(viewModel: viewModel)
          .padding(14)
      }
      .overlay(alignment: .bottomTrailing) {
        VStack(alignment: .trailing, spacing: 12) {
          PolicyCanvasSaveStatusPill(activity: viewModel.saveActivity)
          if minimapVisible, !viewModel.isEmpty {
            PolicyCanvasMinimapOverlay(snapshot: minimapSnapshot) { targetOrigin in
              requestViewportScroll(to: targetOrigin)
            }
          }
          PolicyCanvasShortcutsDisclosure()
        }
        .padding(14)
      }
      .onAppear {
        centerViewportIfNeeded(
          viewportSize: proxy.size,
          routeOutput: routeOutput
        )
        focusSelectionIfNeeded(
          request: selectionFocusRequest,
          viewportSize: proxy.size,
          routeOutput: routeOutput
        )
        bindCommandFocus()
      }
      .onChange(of: viewModel.viewportCenteringGeneration, initial: false) {
        centerViewportIfNeeded(
          viewportSize: proxy.size,
          routeOutput: routeOutput
        )
      }
      .onChange(of: routeOutput.signature, initial: false) {
        centerViewportIfNeeded(
          viewportSize: proxy.size,
          routeOutput: cachedRouteOutput
        )
        focusSelectionIfNeeded(
          request: selectionFocusRequest,
          viewportSize: proxy.size,
          routeOutput: cachedRouteOutput
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
      .harnessFocusedSceneValue(
        \.harnessPolicyCanvasCommandFocus,
        sceneFocusEnabled ? commandFocus : nil
      )
      .task(id: routeKey) {
        await rebuildRoutes()
      }
      .task(id: validationKey) {
        await rebuildValidation()
      }
      .policyCanvasThemeScope()
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.policyCanvasViewport)
  }
}

extension PolicyCanvasViewport {
  @MainActor
  private func bindCommandFocus() {
    bindZoomFocusDispatcher()
    bindLayoutFocusDispatcher()
    let nextFocus = PolicyCanvasCommandFocus(
      zoom: PolicyCanvasZoomFocus(dispatcher: zoomFocusDispatcher),
      layout: PolicyCanvasLayoutFocus(
        canReflow: viewModel.canReflowLayout,
        dispatcher: layoutFocusDispatcher
      )
    )
    guard commandFocus != nextFocus else {
      return
    }
    commandFocus = nextFocus
  }

  @MainActor
  private func rebuildRoutes() async {
    routeGeneration &+= 1
    let generation = routeGeneration
    let input = PolicyCanvasRouteWorkerInput(
      graphGeneration: viewModel.routeComputationGeneration,
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: fontScale,
      routingHints: viewModel.routingHints
    )
    let output = await routeWorker.compute(input: input)
    guard !Task.isCancelled, routeGeneration == generation else {
      return
    }
    if cachedRouteOutput.signature != output.signature {
      cachedRouteOutput = output
    }
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
    routeOutput: PolicyCanvasRouteWorkerOutput
  ) {
    guard
      viewModel.hasPendingViewportCenteringRequest,
      policyCanvasCanCenterViewport(
        isCanvasEmpty: viewModel.isEmpty,
        routeOutputSignature: routeOutput.signature
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
      viewModel.reflowLayout()
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
