import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas view model layout")
@MainActor
struct PolicyCanvasViewModelLayoutTests {
  @Test("loaded default graph starts with clear non-overlapping layout")
  func loadedDefaultGraphStartsWithClearNonOverlappingLayout() {
    let document = overlappingDefaultPolicyDocument(revision: 14)
    let viewModel = PolicyCanvasViewModel.sample()

    viewModel.load(document: document, simulation: nil, audit: nil)

    let groupFrames = Dictionary(uniqueKeysWithValues: viewModel.groups.map { ($0.id, $0.frame) })
    #expect(
      groupFrames.values.allSatisfy { frame in
        frame.minX >= PolicyCanvasLayout.initialContentOrigin.x
          && frame.minY >= PolicyCanvasLayout.initialContentOrigin.y
      }
    )
    #expect(!intersects(groupFrames["entry"], groupFrames["merge"]))
    #expect(!intersects(groupFrames["merge"], groupFrames["terminal"]))
    #expect(!intersects(groupFrames["entry"], groupFrames["terminal"]))
    #expect(!viewModel.nodesContainOverlaps)
    #expect(
      viewModel.nodes.allSatisfy { node in
        guard let groupID = node.groupID, let frame = groupFrames[groupID] else {
          return true
        }
        return frame.contains(CGRect(origin: node.position, size: PolicyCanvasLayout.nodeSize))
      }
    )
    let terminalXPositions = Set(
      viewModel.nodes
        .filter { $0.groupID == "terminal" }
        .map { Int($0.position.x.rounded()) }
    )
    #expect(terminalXPositions.count >= 2)
  }

  @Test("loaded default graph starts centered with balanced canvas whitespace")
  func loadedDefaultGraphStartsCenteredWithBalancedCanvasWhitespace() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    let bounds = viewModel.canvasContentBounds
    let leftWhitespace = bounds.minX
    let rightWhitespace = viewModel.canvasContentSize.width - bounds.maxX
    let topWhitespace = bounds.minY
    let bottomWhitespace = viewModel.canvasContentSize.height - bounds.maxY

    #expect(viewModel.zoom == 1)
    #expect(abs(leftWhitespace - rightWhitespace) <= 1)
    #expect(abs(topWhitespace - bottomWhitespace) <= 1)
    #expect(
      abs(viewModel.initialViewportAnchorPoint.x - (viewModel.canvasContentSize.width / 2)) <= 1
    )
    #expect(
      abs(viewModel.initialViewportAnchorPoint.y - (viewModel.canvasContentSize.height / 2)) <= 1
    )
  }

  @Test(
    "loaded default graph keeps cross-group routes flexible while same-group vertical routes stay pinned"
  )
  func loadedDefaultGraphKeepsCrossGroupRoutesFlexibleWhileSameGroupVerticalRoutesStayPinned() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    let edgesByID = Dictionary(uniqueKeysWithValues: viewModel.edges.map { ($0.id, $0) })

    #expect(edgesByID["edge:evidence-pass"]?.pinnedPortSide == true)
    #expect(edgesByID["edge:default"]?.pinnedPortSide == false)
    #expect(edgesByID["edge:mutate"]?.pinnedPortSide == false)
    #expect(edgesByID["edge:unsafe"]?.pinnedPortSide == false)
    #expect(edgesByID["edge:evidence-consensus"]?.pinnedPortSide == false)
    #expect(edgesByID["edge:evidence-fail:checks-not-green"]?.pinnedPortSide == false)
  }

  @Test("flex routing only offers semantic visible port sides")
  func flexRoutingOnlyOffersSemanticVisiblePortSides() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    guard let edge = viewModel.edges.first(where: { $0.id == "edge:default" }) else {
      Issue.record("Expected default edge")
      return
    }

    let sourceSides = viewModel.portAnchorCandidates(for: edge.source).map { $0.side }
    let targetSides = viewModel.portAnchorCandidates(for: edge.target).map { $0.side }

    #expect(sourceSides == [.trailing, .bottom])
    #expect(targetSides == [.leading, .top])
  }

  @Test("loaded default graph shares route lanes for same terminal targets")
  func loadedDefaultGraphSharesRouteLanesForSameTerminalTargets() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    let lanes = viewModel.edgeRouteLanes
    let actionTerminal = ["edge:default", "edge:mutate", "edge:unsafe"].compactMap { lanes[$0] }
    let mergeDenyFamily = [
      "edge:evidence-fail:checks-not-green",
      "edge:evidence-fail:branch-protection-blocked",
      "edge:evidence-fail:reviewer-not-approved",
      "edge:evidence-fail:unresolved-requested-changes",
    ]
    .compactMap { lanes[$0] }
    let missingEvidenceFamily = [
      "edge:evidence-missing",
      "edge:risk-missing",
    ]
    .compactMap { lanes[$0] }

    #expect(actionTerminal.sorted() == [0, 1, 2])
    #expect(Set(mergeDenyFamily) == Set([0]))
    #expect(Set(missingEvidenceFamily) == Set([0]))
  }

  @Test("loaded default graph assigns distinct fanout lanes across each node side")
  func loadedDefaultGraphAssignsDistinctFanoutLanesAcrossEachNodeSide() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    let sourceLanes = viewModel.edgeSourceFanoutLanes
    let targetLanes = viewModel.edgeTargetFanoutLanes
    let actionSide = ["edge:default", "edge:mutate", "edge:merge", "edge:unsafe"].compactMap {
      sourceLanes[$0]
    }
    let evidenceSide = [
      "edge:evidence-consensus",
      "edge:evidence-missing",
      "edge:evidence-fail:checks-not-green",
      "edge:evidence-fail:branch-protection-blocked",
      "edge:evidence-fail:reviewer-not-approved",
      "edge:evidence-fail:unresolved-requested-changes",
    ]
    .compactMap { sourceLanes[$0] }
    let riskSide = ["edge:risk-low", "edge:risk-high", "edge:risk-missing"].compactMap {
      sourceLanes[$0]
    }
    let mergeDenySourceSide = [
      "edge:evidence-fail:checks-not-green",
      "edge:evidence-fail:branch-protection-blocked",
      "edge:evidence-fail:reviewer-not-approved",
      "edge:evidence-fail:unresolved-requested-changes",
    ]
    .compactMap { sourceLanes[$0] }
    let evidenceOtherSourceSide = [
      "edge:evidence-consensus",
      "edge:evidence-missing",
    ]
    .compactMap { sourceLanes[$0] }
    let mergeDenySide = [
      "edge:evidence-fail:checks-not-green",
      "edge:evidence-fail:branch-protection-blocked",
      "edge:evidence-fail:reviewer-not-approved",
      "edge:evidence-fail:unresolved-requested-changes",
    ]
    .compactMap { targetLanes[$0] }

    #expect(actionSide.sorted() == [0, 1, 2, 3])
    #expect(Set(evidenceSide).count < evidenceSide.count)
    #expect(Set(mergeDenySourceSide) == Set([0]))
    #expect(Set(evidenceOtherSourceSide).count == evidenceOtherSourceSide.count)
    #expect(riskSide.sorted() == [0, 1, 2])
    #expect(Set(mergeDenySide) == Set([0]))
  }

  @Test("route-aware visible bounds drive tighter initial fit")
  func routeAwareVisibleBoundsDriveTighterInitialFit() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    let edges = viewModel.edges
    let portAnchors = viewModel.portAnchors(for: edges)
    let router = PolicyCanvasMemoizedRouter(inner: PolicyCanvasVisibilityRouter())
    let routes = policyCanvasDisplayedRoutes(
      viewModel: viewModel,
      edges: edges,
      portAnchors: portAnchors,
      router: router
    )
    let labelMetrics = PolicyCanvasEdgeLabelMetrics(fontScale: 1)
    let labelPositions = policyCanvasResolvedLabelPositions(
      viewModel: viewModel,
      edges: edges,
      routes: routes,
      fontScale: 1
    )
    let visibleBounds = policyCanvasVisibleBounds(
      viewModel: viewModel,
      edges: edges,
      routes: routes,
      labelPositions: labelPositions,
      labelMetrics: labelMetrics
    )
    let nodeBounds = viewModel.canvasContentBounds
    let fittedZoom = viewModel.fittedInitialZoom(
      for: CGSize(width: 1_280, height: 820),
      contentBounds: visibleBounds
    )

    #expect(visibleBounds.width >= nodeBounds.width)
    #expect(visibleBounds.height >= nodeBounds.height)
    #expect(fittedZoom < viewModel.zoom)
    #expect(fittedZoom >= PolicyCanvasLayout.minimumZoom)
  }

  @Test("edge label metrics fit rendered caption text")
  func edgeLabelMetricsFitRenderedCaptionText() {
    let labels = [
      "default",
      "mutate",
      "unsafe",
      "checks pass",
      "missing risk",
      "fail: reviewer verdict",
    ]
    for fontScale in [CGFloat(1), CGFloat(1.3)] {
      let metrics = PolicyCanvasEdgeLabelMetrics(fontScale: fontScale)
      let font = NSFont.systemFont(ofSize: 11 * fontScale, weight: .semibold)
      for label in labels {
        let availableTextWidth = metrics.size(for: label).width - (metrics.horizontalPadding * 2)
        let renderedTextWidth = (label as NSString).size(withAttributes: [.font: font]).width
        #expect(
          availableTextWidth >= renderedTextWidth.rounded(.up),
          "\(label) estimated width \(availableTextWidth) below rendered \(renderedTextWidth)"
        )
      }
    }
  }

  @Test("presentation bounds normalize leading whitespace for routed content")
  func presentationBoundsNormalizeLeadingWhitespaceForRoutedContent() {
    let visibleBounds = CGRect(x: 180, y: 120, width: 1_060, height: 740)
    let presentedBounds = policyCanvasViewportPresentedBounds(visibleBounds: visibleBounds)
    let presentationOffset = policyCanvasViewportPresentationOffset(
      visibleBounds: visibleBounds
    )
    let contentSize = policyCanvasVisibleContentSize(visibleBounds: visibleBounds)

    #expect(presentedBounds.minX == 1_370)
    #expect(presentedBounds.minY == 1_200)
    #expect(presentationOffset.x == 1_190)
    #expect(presentationOffset.y == 1_080)
    #expect(contentSize.width == 3_800)
    #expect(contentSize.height == 3_140)
  }

  @Test("initial viewport anchor follows presented visible bounds")
  func initialViewportAnchorFollowsPresentedVisibleBounds() {
    let visibleBounds = CGRect(x: 180, y: 120, width: 1_060, height: 740)
    let anchor = policyCanvasInitialViewportAnchorPoint(
      visibleBounds: visibleBounds,
      zoom: 0.6
    )

    #expect(anchor.x == 1_140)
    #expect(anchor.y == 980.4)
  }

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

  @Test("command-scroll canvas point removes presentation offset and fitted content origin")
  func commandScrollCanvasPointRemovesPresentationOffsetAndContentOrigin() {
    let context = PolicyCanvasCommandScrollContext(
      deltaY: 24,
      cursor: CGPoint(x: 420, y: 260),
      preZoomScrollOffset: CGPoint(x: 580, y: 470),
      viewportSize: CGSize(width: 1_280, height: 820),
      contentSize: CGSize(width: 3_800, height: 3_140),
      presentationOffset: CGPoint(x: 1_190, y: 1_080)
    )

    let canvasPoint = policyCanvasCommandScrollCanvasPoint(
      context: context,
      zoom: 0.6
    )

    #expect(abs(canvasPoint.x - 183.333_333_333) < 0.001)
    #expect(abs(canvasPoint.y - 316.666_666_667) < 0.001)
  }

  @Test("command-scroll point keeps the same canvas point under the cursor after zoom")
  func commandScrollPointKeepsCanvasPointAnchoredAfterZoom() {
    let viewModel = PolicyCanvasViewModel.sample()
    let context = PolicyCanvasCommandScrollContext(
      deltaY: 24,
      cursor: CGPoint(x: 420, y: 260),
      preZoomScrollOffset: CGPoint(x: 580, y: 470),
      viewportSize: CGSize(width: 1_280, height: 820),
      contentSize: CGSize(width: 3_800, height: 3_140),
      presentationOffset: CGPoint(x: 1_190, y: 1_080)
    )
    let targetZoom: CGFloat = 0.72
    let canvasPoint = policyCanvasCommandScrollCanvasPoint(
      context: context,
      zoom: 0.6
    )
    let nextScrollPoint = policyCanvasCommandScrollPoint(
      viewModel: viewModel,
      context: context,
      canvasPoint: canvasPoint,
      zoom: targetZoom
    )
    let contentOrigin = policyCanvasViewportContentOrigin(
      viewportSize: context.viewportSize,
      contentSize: context.contentSize,
      zoom: targetZoom
    )
    let scaledCanvasOffset = CGPoint(
      x: (context.presentationOffset.x * targetZoom) + contentOrigin.x,
      y: (context.presentationOffset.y * targetZoom) + contentOrigin.y
    )
    let presentedPoint = CGPoint(
      x: nextScrollPoint.x + context.cursor.x,
      y: nextScrollPoint.y + context.cursor.y
    )
    let recomputedCanvasPoint = policyCanvasCanvasPoint(
      presentedPoint: presentedPoint,
      zoom: targetZoom,
      scaledCanvasOffset: scaledCanvasOffset
    )

    #expect(abs(recomputedCanvasPoint.x - canvasPoint.x) < 0.001)
    #expect(abs(recomputedCanvasPoint.y - canvasPoint.y) < 0.001)
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

  @Test("initial centering waits for computed route output")
  func initialCenteringWaitsForComputedRouteOutput() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    #expect(viewModel.hasPendingViewportCenteringRequest)
    #expect(
      !policyCanvasCanCenterViewport(
        isCanvasEmpty: viewModel.isEmpty,
        routeOutputSignature: .empty
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
        routeOutputSignature: output.signature
      )
    )
    #expect(viewModel.hasPendingViewportCenteringRequest)
  }

  @Test("grouped endpoint routes keep group titles but not group bodies as obstacles")
  func groupedEndpointRoutesKeepGroupTitlesAsObstacles() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    guard let edge = viewModel.edges.first(where: { $0.id == "edge:default" }),
      let source = viewModel.portAnchor(for: edge.source),
      let target = viewModel.portAnchor(for: edge.target),
      let mergeGroup = viewModel.group("merge")
    else {
      Issue.record("Expected default graph anchors and merge group")
      return
    }

    let obstacles = viewModel.routingObstacles(source: source, target: target)
    let titleFrame = policyCanvasGroupTitleFrames([mergeGroup])[0]

    #expect(obstacles.contains(titleFrame))
    #expect(!obstacles.contains(mergeGroup.frame))
  }
}
