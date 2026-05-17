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

  @Test("loaded default graph assigns distinct route lanes within terminal bundles")
  func loadedDefaultGraphAssignsDistinctRouteLanesWithinTerminalBundles() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    let lanes = viewModel.edgeRouteLanes
    let actionTerminal = ["edge:default", "edge:mutate", "edge:unsafe"].compactMap { lanes[$0] }
    let riskTerminal = ["edge:risk-low", "edge:risk-high", "edge:risk-missing"].compactMap {
      lanes[$0]
    }
    let evidenceTerminal = [
      "edge:evidence-consensus",
      "edge:evidence-missing",
      "edge:evidence-fail:checks-not-green",
      "edge:evidence-fail:branch-protection-blocked",
      "edge:evidence-fail:reviewer-not-approved",
      "edge:evidence-fail:unresolved-requested-changes",
    ]
    .compactMap { lanes[$0] }

    #expect(actionTerminal.sorted() == [0, 1, 2])
    #expect(riskTerminal.sorted() == [0, 1, 2])
    #expect(evidenceTerminal.sorted() == [0, 1, 2, 3, 4, 5])
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
    let mergeDenySide = [
      "edge:evidence-fail:checks-not-green",
      "edge:evidence-fail:branch-protection-blocked",
      "edge:evidence-fail:reviewer-not-approved",
      "edge:evidence-fail:unresolved-requested-changes",
    ]
    .compactMap { targetLanes[$0] }

    #expect(actionSide.sorted() == [0, 1, 2, 3])
    #expect(evidenceSide.sorted() == [0, 1, 2, 3, 4, 5])
    #expect(riskSide.sorted() == [0, 1, 2])
    #expect(mergeDenySide.sorted() == [0, 1, 2, 3])
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

    #expect(visibleBounds.width > nodeBounds.width || visibleBounds.height > nodeBounds.height)
    #expect(fittedZoom < viewModel.zoom)
    #expect(fittedZoom >= PolicyCanvasLayout.minimumZoom)
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
    #expect(anchor.y == 942)
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
