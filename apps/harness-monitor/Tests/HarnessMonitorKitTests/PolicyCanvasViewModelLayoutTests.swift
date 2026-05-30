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
    #expect(
      terminalXPositions.count >= 2,
      "terminal x positions: \(terminalXPositions.sorted())"
    )
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
    "loaded default graph keeps cross-group routes flexible while same-group merge routes stay pinned"
  )
  func loadedDefaultGraphKeepsCrossGroupRoutesFlexibleWhileSameGroupMergeRoutesStayPinned() {
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

  @Test("loaded default graph separates route lanes for incompatible terminal families")
  func loadedDefaultGraphSeparatesRouteLanesForIncompatibleTerminalFamilies() {
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

    #expect(actionTerminal.count == 3)
    #expect(Set(actionTerminal).count >= 2)
    #expect(Set(mergeDenyFamily).count == mergeDenyFamily.count)
    #expect(Set(missingEvidenceFamily).count == missingEvidenceFamily.count)
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
    // Incompatible-corridor split: each fail family departs the source on its
    // own fanout lane, so all six evidence-side edges take distinct source
    // lanes (the four merge-deny feeders included). They still converge to a
    // single shared target lane on merge-deny's side (asserted below).
    #expect(Set(evidenceSide).count == evidenceSide.count)
    #expect(Set(mergeDenySourceSide).count == mergeDenySourceSide.count)
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

  @Test("adaptive workspace seeds symmetric guard bands around the logical canvas")
  func adaptiveWorkspaceSeedsSymmetricGuardBandsAroundLogicalCanvas() {
    let layout = policyCanvasInitialAdaptiveWorkspaceLayout(
      contentSize: CGSize(width: 1_200, height: 800),
      viewportSize: CGSize(width: 640, height: 480)
    )

    #expect(layout.contentOrigin.x == 1_200)
    #expect(layout.contentOrigin.y == 1_200)
    #expect(layout.workspaceSize.width == 3_600)
    #expect(layout.workspaceSize.height == 3_200)
  }

  @Test("adaptive workspace expands leading edges and returns the compensating scroll adjustment")
  func adaptiveWorkspaceExpandsLeadingEdgesAndReturnsCompensatingScrollAdjustment() {
    let initialLayout = policyCanvasInitialAdaptiveWorkspaceLayout(
      contentSize: CGSize(width: 1_200, height: 800),
      viewportSize: CGSize(width: 640, height: 480)
    )

    let expansion = policyCanvasExpandedAdaptiveWorkspaceLayout(
      layout: initialLayout,
      visibleWorkspaceRect: CGRect(x: 100, y: 50, width: 640, height: 480),
      viewportSize: CGSize(width: 640, height: 480)
    )

    #expect(expansion.layout.contentOrigin.x == 2_400)
    #expect(expansion.layout.contentOrigin.y == 2_400)
    #expect(expansion.layout.workspaceSize.width == 4_800)
    #expect(expansion.layout.workspaceSize.height == 4_400)
    #expect(expansion.scrollAdjustment.x == 1_200)
    #expect(expansion.scrollAdjustment.y == 1_200)
  }

}
