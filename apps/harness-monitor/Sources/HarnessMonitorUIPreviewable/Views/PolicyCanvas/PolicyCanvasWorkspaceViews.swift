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
  @State private var magnifyStartZoom: CGFloat?
  @State private var zoomFocusDispatcher = PolicyCanvasZoomFocusDispatcher()
  @State private var zoomFocus: PolicyCanvasZoomFocus?
  @State private var hasAppliedRestoredSceneZoom = false
  @State private var currentModifiers: EventModifiers = []
  @State private var hoveredViewportPoint: CGPoint?
  @State private var scrollApplicatorRequest: PolicyCanvasViewportScrollRequest?
  @State private var scrollApplicatorRequestID: UInt64 = 0
  @State private var commandScrollCoordinator = PolicyCanvasCommandScrollCoordinator()
  @State private var routeWorker = PolicyCanvasRouteWorker()
  @State private var routeGeneration: UInt64 = 0
  @State private var validationWorker = PolicyCanvasValidationWorker()
  @State private var validationGeneration: UInt64 = 0
  @State private var cachedRouteOutput = PolicyCanvasRouteWorkerOutput.empty
  @State private var handledSelectionFocusRequestID: UInt64?
  @Environment(\.scenePhase)
  private var scenePhase
  @Environment(\.fontScale)
  private var fontScale

  var magnifyStartZoomValue: CGFloat? {
    get { magnifyStartZoom }
    nonmutating set { magnifyStartZoom = newValue }
  }

  var body: some View {
    let routeOutput = cachedRouteOutput
    let routes = routeOutput.routes
    let labelPositions = routeOutput.labelPositions
    let portVisibility = routeOutput.portVisibility
    let portMarkerLayout = routeOutput.portMarkerLayout
    let edgeAccessibilityLabelsByID = routeOutput.accessibilityEdgeLabelsByID
    let accessibilityNodeEntries = routeOutput.accessibilityNodeEntries
    let accessibilityEdgeEntries = routeOutput.accessibilityEdgeEntries
    let nodeAccessibilityValuesByID = routeOutput.nodeAccessibilityValuesByID
    let connectTargetsByNodeID = routeOutput.connectTargetsByNodeID
    let nodeValidationIssueMessagesByID = viewModel.nodeValidationIssueMessagesByID
    let contentSize = routeOutput.contentSize
    GeometryReader { proxy in
      let edges = viewModel.edges
      let routeKey = PolicyCanvasRouteWorkerKey(
        graphGeneration: viewModel.routeComputationGeneration,
        nodeCount: viewModel.nodes.count,
        groupCount: viewModel.groups.count,
        edgeCount: edges.count,
        fontScale: fontScale
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
      let contentOrigin = policyCanvasViewportContentOrigin(
        viewportSize: proxy.size,
        contentSize: contentSize,
        zoom: viewModel.zoom
      )
      ScrollView([.horizontal, .vertical]) {
        ZStack(alignment: .topLeading) {
          PolicyCanvasDottedGrid(spacing: PolicyCanvasLayout.gridSize * viewModel.zoom)

          ZStack(alignment: .topLeading) {
            PolicyCanvasGroupLayer(viewModel: viewModel, focusedComponent: focusedComponent)
            PolicyCanvasEdgeLayer(
              viewModel: viewModel,
              focusedComponent: focusedComponent,
              edges: edges,
              routes: routes,
              labelPositions: labelPositions,
              accessibilityLabelsByEdgeID: edgeAccessibilityLabelsByID
            )
            PolicyCanvasRubberBandLayer(viewModel: viewModel)
            PolicyCanvasNodeLayer(
              viewModel: viewModel,
              focusedComponent: focusedComponent,
              nodeAccessibilityValuesByID: nodeAccessibilityValuesByID,
              connectTargetsByNodeID: connectTargetsByNodeID,
              nodeValidationIssueMessagesByID: nodeValidationIssueMessagesByID,
              portVisibility: portVisibility,
              portMarkerLayout: portMarkerLayout
            )
            if showSimulationOverlay {
              PolicyCanvasSimulationLayer(viewModel: viewModel)
            }
            PolicyCanvasEdgeLabelLayer(
              viewModel: viewModel,
              focusedComponent: focusedComponent,
              edges: edges,
              routes: routes,
              labelPositions: labelPositions
            )
          }
          .scaleEffect(viewModel.zoom, anchor: viewModel.pinchAnchorUnit ?? .topLeading)
          .offset(x: contentOrigin.x, y: contentOrigin.y)
          .coordinateSpace(.named(PolicyCanvasCoordinateSpaces.canvas))
        }
        .frame(
          width: max(proxy.size.width, contentSize.width * viewModel.zoom),
          height: max(proxy.size.height, contentSize.height * viewModel.zoom),
          alignment: .topLeading
        )
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) {
          PolicyCanvasViewportScrollApplicator(
            request: scrollApplicatorRequest,
            onFulfillRequest: handleViewportScrollRequestFulfilled
          )
          .frame(width: 0, height: 0)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
        }
        .dropDestination(for: String.self) { payloads, location in
          viewModel.dropPalettePayloads(
            payloads,
            at: viewModel.canvasPoint(for: location)
          )
        }
        .onTapGesture {
          viewModel.select(nil)
        }
      }
      .scrollDisabled(viewModel.isEmpty)
      .scrollIndicators(viewModel.isEmpty ? .hidden : .visible)
      .onModifierKeysChanged(mask: .command, initial: true) { _, newModifiers in
        currentModifiers = newModifiers
      }
      .onContinuousHover(coordinateSpace: .local) { phase in
        switch phase {
        case .active(let location):
          hoveredViewportPoint = location
        case .ended:
          hoveredViewportPoint = nil
        }
      }
      .onScrollGeometryChange(for: CGPoint.self, of: \.contentOffset) { oldOffset, newOffset in
        handleScrollOffsetChange(
          oldOffset: oldOffset,
          newOffset: newOffset,
          viewportSize: proxy.size
        )
      }
      .background(Color(red: 0.03, green: 0.04, blue: 0.06))
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
        PolicyCanvasShortcutsDisclosure()
          .padding(14)
      }
      .simultaneousGesture(magnifyGesture(in: proxy.size))
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
        bindZoomFocusDispatcher()
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
          magnifyStartZoom = nil
          viewModel.clearPinchAnchor()
        }
      }
      .harnessFocusedSceneValue(
        \.harnessPolicyCanvasZoomFocus,
        sceneFocusEnabled ? zoomFocus : nil
      )
      .task(id: routeKey) {
        await rebuildRoutes()
      }
      .task(id: validationKey) {
        await rebuildValidation()
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityRotor("Nodes") {
      ForEach(accessibilityNodeEntries) { entry in
        AccessibilityRotorEntry(entry.label, id: entry.id)
      }
    }
    .accessibilityRotor("Edges") {
      ForEach(accessibilityEdgeEntries) { entry in
        AccessibilityRotorEntry(entry.label, id: entry.id)
      }
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.policyCanvasViewport)
  }
}

extension PolicyCanvasViewport {
  @MainActor
  private func rebuildRoutes() async {
    routeGeneration &+= 1
    let generation = routeGeneration
    let input = PolicyCanvasRouteWorkerInput(
      nodes: viewModel.nodes,
      groups: viewModel.groups,
      edges: viewModel.edges,
      fontScale: fontScale
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
      let contentOrigin = policyCanvasViewportContentOrigin(
        viewportSize: viewportSize,
        contentSize: routeOutput.contentSize,
        zoom: targetZoom
      )
      let selectionScrollPoint =
        viewModel.selection.flatMap { selection in
          policyCanvasSelectionViewportScrollPoint(
            selection: selection,
            viewModel: viewModel,
            routeOutput: routeOutput,
            viewportSize: viewportSize,
            zoom: targetZoom,
            contentOrigin: contentOrigin
          )
        }
      requestViewportScroll(
        to: selectionScrollPoint
          ?? policyCanvasInitialViewportScrollPoint(
            visibleBounds: visibleBounds,
            viewportSize: viewportSize,
            zoom: targetZoom,
            contentOrigin: contentOrigin
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
    let contentOrigin = policyCanvasViewportContentOrigin(
      viewportSize: viewportSize,
      contentSize: routeOutput.contentSize,
      zoom: viewModel.zoom
    )
    guard
      let scrollPoint = policyCanvasSelectionViewportScrollPoint(
        selection: request.selection,
        viewModel: viewModel,
        routeOutput: routeOutput,
        viewportSize: viewportSize,
        zoom: viewModel.zoom,
        contentOrigin: contentOrigin
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
    if zoomFocus == nil {
      zoomFocus = PolicyCanvasZoomFocus(dispatcher: zoomFocusDispatcher)
    }
  }

  private func handleScrollOffsetChange(
    oldOffset: CGPoint,
    newOffset: CGPoint,
    viewportSize: CGSize
  ) {
    if commandScrollCoordinator.consumePendingRestoration() {
      return
    }
    guard
      let deltaY = policyCanvasCommandScrollDeltaY(
        isCommandModified: currentModifiers.contains(.command),
        oldOffset: oldOffset,
        newOffset: newOffset
      )
    else {
      return
    }
    let cursor =
      hoveredViewportPoint
      ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    performCommandScrollZoom(
      deltaY: deltaY,
      cursor: cursor,
      preZoomScrollOffset: oldOffset,
      viewportSize: viewportSize
    )
  }

  private func performCommandScrollZoom(
    deltaY: CGFloat,
    cursor: CGPoint,
    preZoomScrollOffset: CGPoint,
    viewportSize: CGSize
  ) {
    let zoomBefore = viewModel.zoom
    let canvasPoint = CGPoint(
      x: (preZoomScrollOffset.x + cursor.x) / zoomBefore,
      y: (preZoomScrollOffset.y + cursor.y) / zoomBefore
    )
    guard
      let targetZoom = policyCanvasCommandScrollTargetZoom(
        currentZoom: zoomBefore,
        deltaY: deltaY
      )
    else {
      commandScrollCoordinator.schedule(
        PolicyCanvasCommandScrollRequest(scrollPoint: preZoomScrollOffset)
      ) { request in
        requestViewportScroll(to: request.scrollPoint)
      }
      return
    }
    let nextScrollPoint = viewModel.viewportScrollPoint(
      keepingCanvasPoint: canvasPoint,
      atViewportPoint: cursor,
      viewportSize: viewportSize,
      zoomOverride: targetZoom
    )
    commandScrollCoordinator.schedule(
      PolicyCanvasCommandScrollRequest(
        zoom: targetZoom,
        scrollPoint: nextScrollPoint
      )
    ) { request in
      if let zoom = request.zoom {
        viewModel.setZoom(zoom)
      }
      requestViewportScroll(to: request.scrollPoint)
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
    if appliesScroll {
      commandScrollCoordinator.armPendingRestoration()
    }
  }

}
