import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension PolicyCanvasViewModelLayoutTests {
  @Test("viewport content origin centers fitted content inside a larger viewport")
  func viewportContentOriginCentersFittedContentInsideLargerViewport() {
    let origin = policyCanvasViewportContentOrigin(
      viewportSize: CGSize(width: 1_640, height: 980),
      contentSize: CGSize(width: 1_000, height: 700),
      zoom: 0.6
    )

    #expect(origin.x == 520)
    #expect(origin.y == 280)
  }

  @Test("viewport content origin stays pinned on overflowing axes")
  func viewportContentOriginStaysPinnedOnOverflowingAxes() {
    let origin = policyCanvasViewportContentOrigin(
      viewportSize: CGSize(width: 1_280, height: 820),
      contentSize: CGSize(width: 2_100, height: 900),
      zoom: 0.7
    )

    #expect(origin.x == 0)
    #expect(origin.y == 95)
  }

  @Test("rendered content size clamps to the viewport on fitted axes")
  func renderedContentSizeClampsToTheViewportOnFittedAxes() {
    let renderedSize = policyCanvasRenderedContentSize(
      viewportSize: CGSize(width: 1_280, height: 820),
      contentSize: CGSize(width: 2_100, height: 900),
      zoom: 0.7
    )

    #expect(renderedSize.width == 1_470)
    #expect(renderedSize.height == 820)
  }

  @Test("document centered scroll point offsets the anchor by the visible document size")
  func documentCenteredScrollPointAccountsForZoom() {
    let scrollPoint = policyCanvasDocumentCenteredScrollPoint(
      anchorPoint: CGPoint(x: 900, y: 680),
      viewportSize: CGSize(width: 640, height: 480),
      zoom: 0.8
    )

    #expect(scrollPoint.x == 500)
    #expect(scrollPoint.y == 380)
  }

  @Test("initial viewport document scroll point centers the anchor in document coordinates")
  func initialViewportDocumentScrollPointCentersAnchor() {
    let visibleBounds = CGRect(x: 520, y: 480, width: 2_000, height: 1_200)
    let viewportSize = CGSize(width: 800, height: 600)
    let zoom: CGFloat = 0.8
    let scrollPoint = policyCanvasInitialViewportDocumentScrollPoint(
      visibleBounds: visibleBounds,
      viewportSize: viewportSize,
      zoom: zoom
    )
    let expectedAnchor = policyCanvasInitialViewportAnchorPoint(
      visibleBounds: visibleBounds,
      zoom: 1
    )

    #expect(abs((scrollPoint.x + (viewportSize.width / (zoom * 2))) - expectedAnchor.x) < 0.001)
    #expect(abs((scrollPoint.y + (viewportSize.height / (zoom * 2))) - expectedAnchor.y) < 0.001)
  }

  @Test("pasted PR dry-run route output stays centered with balanced visible whitespace")
  func pastedPRDryRunRouteOutputStaysCenteredWithBalancedVisibleWhitespace() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: policyCanvasPastedPRDryRunDocument(),
      simulation: nil,
      audit: nil
    )

    let routeOutput = await PolicyCanvasRouteWorker(router: PolicyCanvasVisibilityRouter())
      .compute(
        input: PolicyCanvasRouteWorkerInput(
          graphGeneration: viewModel.routeComputationGeneration,
          nodes: viewModel.nodes,
          groups: viewModel.groups,
          edges: viewModel.edges,
          fontScale: 1,
          routingHints: viewModel.routingHints
        )
      )

    let leftWhitespace = routeOutput.visibleBounds.minX
    let rightWhitespace = routeOutput.contentSize.width - routeOutput.visibleBounds.maxX
    let topWhitespace = routeOutput.visibleBounds.minY
    let bottomWhitespace = routeOutput.contentSize.height - routeOutput.visibleBounds.maxY

    #expect(abs(leftWhitespace - rightWhitespace) <= 1)
    #expect(abs(topWhitespace - bottomWhitespace) <= 1)
  }

  @Test("centered scroll point offsets the anchor by half the viewport")
  func centeredScrollPointOffsetsTheAnchorByHalfTheViewport() {
    let scrollPoint = policyCanvasCenteredScrollPoint(
      anchorPoint: CGPoint(x: 900, y: 680),
      viewportSize: CGSize(width: 640, height: 480)
    )

    #expect(scrollPoint.x == 580)
    #expect(scrollPoint.y == 440)
  }

  @Test("centered scroll point clamps negative offsets to zero")
  func centeredScrollPointClampsNegativeOffsetsToZero() {
    let scrollPoint = policyCanvasCenteredScrollPoint(
      anchorPoint: CGPoint(x: 180, y: 120),
      viewportSize: CGSize(width: 640, height: 480)
    )

    #expect(scrollPoint.x == 0)
    #expect(scrollPoint.y == 0)
  }

  @Test("initial viewport scroll point centers the presented anchor directly")
  func initialViewportScrollPointCentersThePresentedAnchorDirectly() {
    let scrollPoint = policyCanvasInitialViewportScrollPoint(
      visibleBounds: CGRect(x: 180, y: 120, width: 1_060, height: 740),
      viewportSize: CGSize(width: 1_280, height: 820),
      zoom: 0.6
    )

    #expect(scrollPoint.x == 500)
    #expect(abs(scrollPoint.y - 570.4) < 0.001)
  }

  @Test("initial viewport scroll point includes content origin in document coordinates")
  func initialViewportScrollPointIncludesContentOrigin() {
    let visibleBounds = CGRect(x: 520, y: 480, width: 2_000, height: 1_200)
    let viewportSize = CGSize(width: 800, height: 600)
    let contentOrigin = CGPoint(x: 180, y: 120)
    let scrollPoint = policyCanvasInitialViewportScrollPoint(
      visibleBounds: visibleBounds,
      viewportSize: viewportSize,
      zoom: 1,
      contentOrigin: contentOrigin
    )
    let expectedAnchor = CGPoint(
      x: policyCanvasInitialViewportAnchorPoint(
        visibleBounds: visibleBounds,
        zoom: 1
      ).x + contentOrigin.x,
      y: policyCanvasInitialViewportAnchorPoint(
        visibleBounds: visibleBounds,
        zoom: 1
      ).y + contentOrigin.y
    )

    #expect(abs((scrollPoint.x + (viewportSize.width / 2)) - expectedAnchor.x) < 0.001)
    #expect(abs((scrollPoint.y + (viewportSize.height / 2)) - expectedAnchor.y) < 0.001)
  }

  @Test("selection viewport scroll point centers the selected node directly")
  func selectionViewportScrollPointCentersSelectedNodeDirectly() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    let routeOutput = await PolicyCanvasRouteWorker(router: PolicyCanvasVisibilityRouter())
      .compute(
        input: PolicyCanvasRouteWorkerInput(
          nodes: viewModel.nodes,
          groups: viewModel.groups,
          edges: viewModel.edges,
          fontScale: 1
        )
      )
    let viewportSize = CGSize(width: 1_280, height: 820)
    let contentOrigin = policyCanvasViewportContentOrigin(
      viewportSize: viewportSize,
      contentSize: routeOutput.contentSize,
      zoom: viewModel.zoom
    )

    guard
      let node = viewModel.node("action:router"),
      let scrollPoint = policyCanvasSelectionViewportScrollPoint(
        selection: .node("action:router"),
        viewModel: viewModel,
        routeOutput: routeOutput,
        viewportSize: viewportSize,
        zoom: viewModel.zoom,
        contentOrigin: contentOrigin
      )
    else {
      Issue.record("Expected selected node focus point")
      return
    }

    let frame = policyCanvasNodeFrame(node)
    let expectedAnchor = CGPoint(
      x: (frame.midX * viewModel.zoom) + contentOrigin.x,
      y: (frame.midY * viewModel.zoom) + contentOrigin.y
    )

    #expect(abs((scrollPoint.x + (viewportSize.width / 2)) - expectedAnchor.x) < 0.001)
    #expect(abs((scrollPoint.y + (viewportSize.height / 2)) - expectedAnchor.y) < 0.001)
  }

  @Test(
    "selection viewport document scroll point centers the selected node in document coordinates")
  func selectionViewportDocumentScrollPointCentersSelectedNodeDirectly() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    let routeOutput = await PolicyCanvasRouteWorker(router: PolicyCanvasVisibilityRouter())
      .compute(
        input: PolicyCanvasRouteWorkerInput(
          nodes: viewModel.nodes,
          groups: viewModel.groups,
          edges: viewModel.edges,
          fontScale: 1
        )
      )
    let viewportSize = CGSize(width: 1_280, height: 820)
    let zoom = viewModel.zoom

    guard
      let node = viewModel.node("action:router"),
      let scrollPoint = policyCanvasSelectionViewportDocumentScrollPoint(
        selection: .node("action:router"),
        viewModel: viewModel,
        routeOutput: routeOutput,
        viewportSize: viewportSize,
        zoom: zoom
      )
    else {
      Issue.record("Expected selected node focus point")
      return
    }

    let frame = policyCanvasNodeFrame(node)
    let expectedAnchor = CGPoint(x: frame.midX, y: frame.midY)

    #expect(abs((scrollPoint.x + (viewportSize.width / (zoom * 2))) - expectedAnchor.x) < 0.001)
    #expect(abs((scrollPoint.y + (viewportSize.height / (zoom * 2))) - expectedAnchor.y) < 0.001)
  }

  @Test("initial centering waits for computed route output")
  func initialCenteringWaitsForComputedRouteOutput() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )
    let currentRouteKey = PolicyCanvasRouteWorkerKey(
      graphGeneration: viewModel.routeComputationGeneration,
      nodeCount: viewModel.nodes.count,
      groupCount: viewModel.groups.count,
      edgeCount: viewModel.edges.count,
      fontScale: 1,
      routingHints: viewModel.routingHints
    )

    #expect(viewModel.hasPendingViewportCenteringRequest)
    #expect(
      !policyCanvasCanCenterViewport(
        isCanvasEmpty: viewModel.isEmpty,
        routeOutputSignature: .empty,
        currentRouteKey: currentRouteKey,
        appliedRouteKey: nil
      )
    )
    #expect(
      !policyCanvasCanCenterViewport(
        isCanvasEmpty: viewModel.isEmpty,
        routeOutputSignature: .empty,
        currentRouteKey: currentRouteKey,
        appliedRouteKey: currentRouteKey
      )
    )

    let output = await PolicyCanvasRouteWorker(router: PolicyCanvasVisibilityRouter())
      .compute(
        input: PolicyCanvasRouteWorkerInput(
          nodes: viewModel.nodes,
          groups: viewModel.groups,
          edges: viewModel.edges,
          fontScale: 1
        )
      )

    #expect(
      policyCanvasCanCenterViewport(
        isCanvasEmpty: viewModel.isEmpty,
        routeOutputSignature: output.signature,
        currentRouteKey: currentRouteKey,
        appliedRouteKey: currentRouteKey
      )
    )
    #expect(
      !policyCanvasCanCenterViewport(
        isCanvasEmpty: viewModel.isEmpty,
        routeOutputSignature: output.signature,
        currentRouteKey: PolicyCanvasRouteWorkerKey(
          graphGeneration: currentRouteKey.graphGeneration &+ 1,
          nodeCount: currentRouteKey.nodeCount,
          groupCount: currentRouteKey.groupCount,
          edgeCount: currentRouteKey.edgeCount,
          fontScale: currentRouteKey.fontScale,
          routingHints: currentRouteKey.routingHints
        ),
        appliedRouteKey: currentRouteKey
      )
    )
    #expect(viewModel.hasPendingViewportCenteringRequest)
  }

  @Test("initial load centers from cheap fallback routes without requesting route work")
  func initialLoadCentersFromFallbackRoutesWithoutRequestingRouteWork() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )
    let currentRouteKey = PolicyCanvasRouteWorkerKey(
      graphGeneration: viewModel.routeComputationGeneration,
      nodeCount: viewModel.nodes.count,
      groupCount: viewModel.groups.count,
      edgeCount: viewModel.edges.count,
      fontScale: 1,
      routingHints: viewModel.routingHints
    )
    let provisionalOutput = PolicyCanvasRouteWorkerOutput.fallback(
      for: PolicyCanvasRouteWorkerInput(
        graphGeneration: viewModel.routeComputationGeneration,
        nodes: viewModel.nodes,
        groups: viewModel.groups,
        edges: viewModel.edges,
        fontScale: 1,
        routingHints: viewModel.routingHints
      )
    )

    #expect(
      policyCanvasCanCenterViewport(
        isCanvasEmpty: viewModel.isEmpty,
        routeOutputSignature: provisionalOutput.signature,
        currentRouteKey: currentRouteKey,
        appliedRouteKey: nil,
        routeOutputIsCurrentGraphProvisional: true
      )
    )
    #expect(provisionalOutput.routes.count == viewModel.edges.count)
    #expect(viewModel.routeComputationRequestGeneration == 0)
  }

  @Test("a reflow re-requests viewport centering so a switched or reformatted canvas lands on content")
  func reflowReRequestsViewportCentering() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )
    // The load itself asks to center; clear that so the assertion observes the
    // reflow's own request rather than the load's.
    _ = viewModel.consumeViewportCenteringRequest()
    #expect(!viewModel.hasPendingViewportCenteringRequest)

    // Shove a node well off its tidy spot so the forced reflow has real work and
    // actually relocates nodes - the exact situation (a canvas switch that
    // force-reflows, or a manual Reformat) that left the viewport framing empty
    // space before the recenter request was added.
    if !viewModel.nodes.isEmpty {
      viewModel.nodes[0].position = CGPoint(
        x: viewModel.nodes[0].position.x + 1_200,
        y: viewModel.nodes[0].position.y + 800
      )
    }
    viewModel.reflowLayout(preserveManualAnchors: false, force: true)

    #expect(viewModel.hasPendingViewportCenteringRequest)
  }

  @Test("Reformat requests viewport centering even when a tidy layout does not move")
  func tidyReformatRequestsViewportCentering() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: seededDefaultPolicyDocument(revision: 944),
      simulation: nil,
      audit: nil
    )
    _ = viewModel.consumeViewportCenteringRequest()
    #expect(!viewModel.hasPendingViewportCenteringRequest)

    viewModel.reflowLayout()

    #expect(viewModel.hasPendingViewportCenteringRequest)
    #expect(viewModel.viewportCenteringBehavior == .documentAfterRouteComputation)
  }

  @Test("manual reflow explicitly requests route computation")
  func manualReflowExplicitlyRequestsRouteComputation() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )
    let previousRequestGeneration = viewModel.routeComputationRequestGeneration

    viewModel.reflowLayout()

    #expect(viewModel.routeComputationRequestGeneration == previousRequestGeneration &+ 1)
  }

  @Test("empty canvas can center once fresh empty route data arrives")
  func emptyCanvasCanCenterAfterFreshEmptyRouteDataArrives() {
    let routeKey = PolicyCanvasRouteWorkerKey(
      graphGeneration: 0,
      nodeCount: 0,
      groupCount: 0,
      edgeCount: 0,
      fontScale: 1,
      routingHints: nil
    )

    #expect(
      policyCanvasCanCenterViewport(
        isCanvasEmpty: true,
        routeOutputSignature: .empty,
        currentRouteKey: routeKey,
        appliedRouteKey: routeKey
      )
    )
  }

  @Test("explicit Reformat centering waits for applied route output")
  func explicitReformatCenteringWaitsForAppliedRouteOutput() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )
    let routeKey = PolicyCanvasRouteWorkerKey(
      graphGeneration: viewModel.routeComputationGeneration,
      nodeCount: viewModel.nodes.count,
      groupCount: viewModel.groups.count,
      edgeCount: viewModel.edges.count,
      fontScale: 1,
      routingHints: viewModel.routingHints
    )
    let routeSignature = PolicyCanvasRouteWorkerOutput.fallback(
      for: PolicyCanvasRouteWorkerInput(
        graphGeneration: viewModel.routeComputationGeneration,
        nodes: viewModel.nodes,
        groups: viewModel.groups,
        edges: viewModel.edges,
        fontScale: 1,
        routingHints: viewModel.routingHints
      )
    )
    .signature

    #expect(
      !policyCanvasCanCenterViewport(
        isCanvasEmpty: false,
        routeOutputSignature: routeSignature,
        currentRouteKey: routeKey,
        appliedRouteKey: nil,
        routeOutputIsCurrentGraphProvisional: true,
        allowsProvisionalRouteOutput: false
      )
    )
    #expect(
      policyCanvasCanCenterViewport(
        isCanvasEmpty: false,
        routeOutputSignature: routeSignature,
        currentRouteKey: routeKey,
        appliedRouteKey: routeKey,
        routeOutputIsCurrentGraphProvisional: true,
        allowsProvisionalRouteOutput: false
      )
    )
  }

}
