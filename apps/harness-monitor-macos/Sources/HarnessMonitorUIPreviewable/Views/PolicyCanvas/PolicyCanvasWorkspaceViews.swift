import SwiftUI

struct PolicyCanvasViewport: View {
  let viewModel: PolicyCanvasViewModel
  let focusedComponent: AccessibilityFocusState<PolicyCanvasSelection?>.Binding
  var showSimulationOverlay: Bool = false
  var suppressesSceneStorage = false
  var storedPipelineStateRaw = ""
  @State private var magnifyStartZoom: CGFloat?
  @State private var zoomFocusDispatcher = PolicyCanvasZoomFocusDispatcher()
  @State private var zoomFocus: PolicyCanvasZoomFocus?
  @State private var hasAppliedRestoredSceneZoom = false
  @State private var currentModifiers: EventModifiers = []
  @State private var hoveredViewportPoint: CGPoint?
  @State private var scrollPosition = ScrollPosition()
  @State private var measuredScrollContentSize: CGSize = .zero
  @State private var pendingCenteredScrollPoint: CGPoint?
  @State private var pendingCenteredContentSize: CGSize?
  @State private var isRestoringCommandScrollPosition = false
  @Environment(\.scenePhase)
  private var scenePhase
  @Environment(\.policyCanvasEdgeRouter)
  private var router
  @Environment(\.fontScale)
  private var fontScale

  var magnifyStartZoomValue: CGFloat? {
    get { magnifyStartZoom }
    nonmutating set { magnifyStartZoom = newValue }
  }

  var body: some View {
    GeometryReader { proxy in
      ScrollViewReader { _ in
        let edges = viewModel.edges
        let portAnchors = viewModel.portAnchors(for: edges)
        let routes = policyCanvasDisplayedRoutes(
          viewModel: viewModel,
          edges: edges,
          portAnchors: portAnchors,
          router: router
        )
        let labelMetrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
        let labelPositions = policyCanvasResolvedLabelPositions(
          viewModel: viewModel,
          edges: edges,
          routes: routes,
          fontScale: fontScale
        )
        let visibleBounds = policyCanvasVisibleBounds(
          viewModel: viewModel,
          edges: edges,
          routes: routes,
          labelPositions: labelPositions,
          labelSize: CGSize(
            width: PolicyCanvasLayout.edgeLabelMaxWidth,
            height: labelMetrics.height
          )
        )
        let presentationOffset = policyCanvasViewportPresentationOffset(
          visibleBounds: visibleBounds
        )
        let contentSize = policyCanvasVisibleContentSize(visibleBounds: visibleBounds)
        let contentOrigin = policyCanvasViewportContentOrigin(
          viewportSize: proxy.size,
          contentSize: contentSize,
          zoom: viewModel.zoom
        )
        let renderedContentSize = policyCanvasRenderedContentSize(
          viewportSize: proxy.size,
          contentSize: contentSize,
          zoom: viewModel.zoom
        )
        let scaledCanvasOffset = CGPoint(
          x: (presentationOffset.x * viewModel.zoom) + contentOrigin.x,
          y: (presentationOffset.y * viewModel.zoom) + contentOrigin.y
        )
        ScrollView([.horizontal, .vertical]) {
          ZStack(alignment: .topLeading) {
            PolicyCanvasDottedGrid(spacing: PolicyCanvasLayout.gridSize * viewModel.zoom)

            Color.clear
              .frame(width: 1, height: 1)
              .position(
                policyCanvasInitialViewportAnchorPoint(
                  visibleBounds: visibleBounds,
                  zoom: viewModel.zoom
                )
                .applying(
                  CGAffineTransform(
                    translationX: contentOrigin.x,
                    y: contentOrigin.y
                  )
                )
              )
              .id(PolicyCanvasLayout.initialViewportAnchorID)
              .accessibilityHidden(true)

            ZStack(alignment: .topLeading) {
              PolicyCanvasGroupLayer(viewModel: viewModel, focusedComponent: focusedComponent)
              PolicyCanvasEdgeLayer(
                viewModel: viewModel,
                focusedComponent: focusedComponent,
                edges: edges,
                routes: routes
              )
              PolicyCanvasRubberBandLayer(viewModel: viewModel)
              PolicyCanvasNodeLayer(viewModel: viewModel, focusedComponent: focusedComponent)
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
            .offset(x: scaledCanvasOffset.x, y: scaledCanvasOffset.y)
            .coordinateSpace(.named(PolicyCanvasCoordinateSpaces.canvas))
          }
          .frame(
            width: renderedContentSize.width,
            height: renderedContentSize.height,
            alignment: .topLeading
          )
          .contentShape(Rectangle())
          .dropDestination(for: String.self) { payloads, location in
            viewModel.dropPalettePayloads(
              payloads,
              at: viewModel.canvasPoint(
                for: location,
                scaledCanvasOffset: scaledCanvasOffset
              )
            )
          }
          .onTapGesture {
            viewModel.select(nil)
          }
        }
        .scrollDisabled(viewModel.isEmpty)
        .scrollIndicators(viewModel.isEmpty ? .hidden : .visible)
        .scrollPosition($scrollPosition)
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
            viewportSize: proxy.size,
            contentSize: contentSize,
            presentationOffset: presentationOffset
          )
        }
        .onScrollGeometryChange(for: CGSize.self) { geometry in
          geometry.contentSize
        } action: { _, newContentSize in
          measuredScrollContentSize = newContentSize
          applyPendingCenteredScrollIfNeeded()
        }
        .background(Color(red: 0.03, green: 0.04, blue: 0.06))
        .clipShape(Rectangle())
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
            visibleBounds: visibleBounds
          )
          bindZoomFocusDispatcher()
        }
        .onChange(of: viewModel.viewportCenteringGeneration, initial: false) {
          centerViewportIfNeeded(
            viewportSize: proxy.size,
            visibleBounds: visibleBounds
          )
        }
        .onChange(of: scenePhase) { _, newPhase in
          if newPhase != .active {
            magnifyStartZoom = nil
            viewModel.clearPinchAnchor()
          }
        }
        .focusedSceneValue(\.harnessPolicyCanvasZoomFocus, zoomFocus)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityRotor("Nodes") {
      ForEach(viewModel.accessibilityNodeFocusOrder(), id: \.self) { nodeID in
        if let node = viewModel.node(nodeID) {
          AccessibilityRotorEntry(
            viewModel.accessibilityLabel(for: node),
            id: nodeID
          )
        }
      }
    }
    .accessibilityRotor("Edges") {
      ForEach(viewModel.edges, id: \.id) { edge in
        AccessibilityRotorEntry(
          viewModel.accessibilityLabel(for: edge),
          id: edge.id
        )
      }
    }
    .accessibilityFrameMarker(HarnessMonitorAccessibility.policyCanvasViewport)
  }
}

extension PolicyCanvasViewport {
  fileprivate func centerViewportIfNeeded(
    viewportSize: CGSize,
    visibleBounds: CGRect
  ) {
    guard viewModel.consumeViewportCenteringRequest() else {
      return
    }
    let contentSize = policyCanvasVisibleContentSize(visibleBounds: visibleBounds)
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
    let targetContentOrigin = policyCanvasViewportContentOrigin(
      viewportSize: viewportSize,
      contentSize: contentSize,
      zoom: targetZoom
    )
    let targetAnchorPoint =
      policyCanvasInitialViewportAnchorPoint(
        visibleBounds: visibleBounds,
        zoom: targetZoom
      )
      .applying(
        CGAffineTransform(
          translationX: targetContentOrigin.x,
          y: targetContentOrigin.y
        )
      )
    let targetScrollPoint = policyCanvasCenteredScrollPoint(
      anchorPoint: targetAnchorPoint,
      viewportSize: viewportSize
    )
    let targetRenderedContentSize = policyCanvasRenderedContentSize(
      viewportSize: viewportSize,
      contentSize: contentSize,
      zoom: targetZoom
    )
    pendingCenteredScrollPoint = targetScrollPoint
    pendingCenteredContentSize = targetRenderedContentSize
    applyPendingCenteredScrollIfNeeded()
  }

  fileprivate func bindZoomFocusDispatcher() {
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

  fileprivate func handleScrollOffsetChange(
    oldOffset: CGPoint,
    newOffset: CGPoint,
    viewportSize: CGSize,
    contentSize: CGSize,
    presentationOffset: CGPoint
  ) {
    if isRestoringCommandScrollPosition {
      isRestoringCommandScrollPosition = false
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
      PolicyCanvasCommandScrollContext(
        deltaY: deltaY,
        cursor: cursor,
        preZoomScrollOffset: oldOffset,
        viewportSize: viewportSize,
        contentSize: contentSize,
        presentationOffset: presentationOffset
      )
    )
  }

  fileprivate func performCommandScrollZoom(_ context: PolicyCanvasCommandScrollContext) {
    let canvasPoint = policyCanvasCommandScrollCanvasPoint(
      context: context,
      zoom: viewModel.zoom
    )
    guard viewModel.zoomByCommandScroll(deltaY: context.deltaY) else {
      isRestoringCommandScrollPosition = true
      scrollPosition = ScrollPosition(point: context.preZoomScrollOffset)
      return
    }
    let nextScrollPoint = policyCanvasCommandScrollPoint(
      viewModel: viewModel,
      context: context,
      canvasPoint: canvasPoint
    )
    isRestoringCommandScrollPosition = true
    scrollPosition = ScrollPosition(point: nextScrollPoint)
  }

  fileprivate func applyPendingCenteredScrollIfNeeded() {
    guard
      let pendingCenteredScrollPoint,
      let pendingCenteredContentSize,
      measuredScrollContentSize.width > 0,
      measuredScrollContentSize.height > 0
    else {
      return
    }
    guard
      abs(measuredScrollContentSize.width - pendingCenteredContentSize.width) <= 1,
      abs(measuredScrollContentSize.height - pendingCenteredContentSize.height) <= 1
    else {
      return
    }
    isRestoringCommandScrollPosition = true
    scrollPosition = ScrollPosition(point: pendingCenteredScrollPoint)
    self.pendingCenteredScrollPoint = nil
    self.pendingCenteredContentSize = nil
  }

}
