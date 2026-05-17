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
      labelSize: CGSize(
        width: PolicyCanvasLayout.edgeLabelMaxWidth,
        height: labelMetrics.height
      )
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

  @Test("grouped endpoint routes still include intervening groups as obstacles")
  func groupedEndpointRoutesStillIncludeInterveningGroupsAsObstacles() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(),
      simulation: nil,
      audit: nil
    )

    guard let edge = viewModel.edges.first(where: { $0.id == "edge:default" }),
      let source = viewModel.portAnchor(for: edge.source),
      let target = viewModel.portAnchor(for: edge.target),
      let mergeFrame = viewModel.group("merge")?.frame
    else {
      Issue.record("Expected default graph anchors and merge group frame")
      return
    }

    let obstacles = viewModel.routingObstacles(source: source, target: target)

    #expect(obstacles.contains(mergeFrame))
  }
}
