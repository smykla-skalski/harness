import AppKit
import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

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

  @Test("live startup trusts persisted canvas coordinates instead of repairing layout")
  func liveStartupTrustsPersistedCanvasCoordinates() {
    let document = overlappingDefaultPolicyDocument(revision: 15)
    let rawPositions = Dictionary(
      uniqueKeysWithValues: document.layout.nodes.map { layout in
        (layout.nodeId.rawValue, CGPoint(x: CGFloat(layout.x), y: CGFloat(layout.y)))
      }
    )

    let viewModel = PolicyCanvasViewModel.liveStartupState(
      document: document,
      simulation: nil,
      audit: nil,
      activeCanvasId: "default-canvas"
    )

    for node in viewModel.nodes {
      #expect(node.position == rawPositions[node.id])
    }
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

  @Test("loaded pasted PR dry-run graph starts centered with balanced canvas whitespace")
  func loadedPastedPRDryRunGraphStartsCenteredWithBalancedCanvasWhitespace() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: policyCanvasPastedPRDryRunDocument(),
      simulation: nil,
      audit: nil
    )

    let bounds = viewModel.canvasContentBounds
    let leftWhitespace = bounds.minX
    let rightWhitespace = viewModel.canvasContentSize.width - bounds.maxX
    let topWhitespace = bounds.minY
    let bottomWhitespace = viewModel.canvasContentSize.height - bounds.maxY

    #expect(abs(leftWhitespace - rightWhitespace) <= 1)
    #expect(abs(topWhitespace - bottomWhitespace) <= 1)
    #expect(
      abs(viewModel.initialViewportAnchorPoint.x - (viewModel.canvasContentSize.width / 2)) <= 1
    )
    #expect(
      abs(viewModel.initialViewportAnchorPoint.y - (viewModel.canvasContentSize.height / 2)) <= 1
    )
  }

  @Test("switching to the pasted PR dry-run graph keeps centered canvas whitespace")
  func switchingToPastedPRDryRunGraphKeepsCenteredCanvasWhitespace() {
    let viewModel = PolicyCanvasViewModel.liveStartupState(
      document: PolicyPipelineDocument(
        revision: 1,
        mode: .draft,
        nodes: [],
        edges: [],
        groups: []
      ),
      simulation: nil,
      audit: nil,
      activeCanvasId: "default-canvas"
    )

    viewModel.applyDocument(
      document: policyCanvasPastedPRDryRunDocument(),
      simulation: nil,
      audit: nil,
      activeCanvasId: "pasted-pr-canvas",
      forceDocumentReload: true
    )

    let bounds = viewModel.canvasContentBounds
    let leftWhitespace = bounds.minX
    let rightWhitespace = viewModel.canvasContentSize.width - bounds.maxX
    let topWhitespace = bounds.minY
    let bottomWhitespace = viewModel.canvasContentSize.height - bounds.maxY

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
    // The merge-deny fail family folds into one error wire, which is
    // intentionally pinned (effectivePinnedPortSide), so it is excluded from this
    // normal-edge flex heuristic.
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

    // Each port leads with its natural horizontal side, then offers both vertical
    // sides as router alternates: an output can drop from its bottom or - when it
    // sits below its target in a fan-in - exit upward from its top; an input
    // mirrors. The forbidden opposite horizontal side never appears (an output
    // never offers leading, an input never offers trailing).
    #expect(sourceSides == [.trailing, .bottom, .top])
    #expect(targetSides == [.leading, .top, .bottom])
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
