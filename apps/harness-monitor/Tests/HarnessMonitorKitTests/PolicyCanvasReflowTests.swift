import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas reflow")
@MainActor
struct PolicyCanvasReflowTests {
  @Test("reflow preserves manual anchors and refreshes edge port hints")
  func reflowPreservesManualAnchorsAndRefreshesEdgeHints() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.load(document: overlappingReflowDocument(revision: 900), simulation: nil, audit: nil)

    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .auto })

    guard let sourceIndex = viewModel.nodes.firstIndex(where: { $0.id == "source-node" }) else {
      Issue.record("Expected source node for reflow test")
      return
    }
    let anchoredSource = CGPoint(x: 640, y: 220)
    viewModel.nodes[sourceIndex].position = anchoredSource
    viewModel.nodes[sourceIndex].layoutSource = .manual
    guard viewModel.node("source-node")?.position == anchoredSource else {
      Issue.record("Expected anchored source node after drag")
      return
    }

    let displacedTarget = CGPoint(x: anchoredSource.x + 920, y: anchoredSource.y + 260)
    guard let targetIndex = viewModel.nodes.firstIndex(where: { $0.id == "target-node" }) else {
      Issue.record("Expected target node for reflow test")
      return
    }
    viewModel.nodes[targetIndex].position = displacedTarget
    guard let edgeIndex = viewModel.edges.firstIndex(where: { $0.id == "source-target" }) else {
      Issue.record("Expected single edge for reflow test")
      return
    }
    let staleRoutingHintsBeforeReflow = viewModel.routingHints
    guard let prediction = predictedReflow(viewModel: viewModel, edgeIndex: edgeIndex) else {
      Issue.record("Expected a predicted layout result for reflow test")
      return
    }
    let expectedRoutingHintsAfterReflow = prediction.routingHints
    let expectedEdgeAfterReflow = prediction.edge
    viewModel.edges[edgeIndex].source.side = alternateSide(for: expectedEdgeAfterReflow.source.side)
    viewModel.edges[edgeIndex].target.side = alternateSide(for: expectedEdgeAfterReflow.target.side)
    viewModel.edges[edgeIndex].pinnedPortSide = false
    let staleEdgeBeforeReflow = viewModel.edges[edgeIndex]

    viewModel.reflowLayout()

    guard
      let sourceAfterReflow = viewModel.node("source-node"),
      let targetAfterReflow = viewModel.node("target-node")
    else {
      Issue.record("Expected live nodes after reflow")
      return
    }
    let edgeAfterReflow = viewModel.edges[edgeIndex]
    #expect(sourceAfterReflow.position == anchoredSource)
    #expect(sourceAfterReflow.layoutSource == .manual)
    #expect(targetAfterReflow.layoutSource == .auto)
    #expect(targetAfterReflow.position != displacedTarget)
    #expect(targetAfterReflow.position.x > anchoredSource.x)
    #expect(edgeAfterReflow.source.side == expectedEdgeAfterReflow.source.side)
    #expect(edgeAfterReflow.target.side == expectedEdgeAfterReflow.target.side)
    #expect(edgeAfterReflow.source.side != staleEdgeBeforeReflow.source.side)
    #expect(edgeAfterReflow.target.side != staleEdgeBeforeReflow.target.side)
    #expect(edgeAfterReflow.pinnedPortSide == false)
    #expect(viewModel.routingHints == expectedRoutingHintsAfterReflow)
    #expect(undoManager.canUndo)

    undoManager.undo()

    guard
      let sourceAfterUndo = viewModel.node("source-node"),
      let targetAfterUndo = viewModel.node("target-node")
    else {
      Issue.record("Expected live nodes after undo")
      return
    }
    let edgeAfterUndo = viewModel.edges[edgeIndex]
    #expect(sourceAfterUndo.position == anchoredSource)
    #expect(sourceAfterUndo.layoutSource == .manual)
    #expect(targetAfterUndo.position == displacedTarget)
    #expect(targetAfterUndo.layoutSource == .auto)
    #expect(edgeAfterUndo.source.side == staleEdgeBeforeReflow.source.side)
    #expect(edgeAfterUndo.target.side == staleEdgeBeforeReflow.target.side)
    #expect(edgeAfterUndo.pinnedPortSide == false)
    #expect(viewModel.routingHints == staleRoutingHintsBeforeReflow)
  }

  @Test("reflow falls back to laying out all nodes when every node is manual")
  func reflowFallsBackToLayingOutAllManualNodes() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.load(document: overlappingReflowDocument(revision: 901), simulation: nil, audit: nil)

    let manualSource = CGPoint(x: 1_180, y: 940)
    let manualTarget = CGPoint(x: 760, y: 260)
    guard
      let sourceIndex = viewModel.nodes.firstIndex(where: { $0.id == "source-node" }),
      let targetIndex = viewModel.nodes.firstIndex(where: { $0.id == "target-node" })
    else {
      Issue.record("Expected source and target nodes for manual reflow test")
      return
    }

    viewModel.nodes[sourceIndex].position = manualSource
    viewModel.nodes[sourceIndex].layoutSource = .manual
    viewModel.nodes[targetIndex].position = manualTarget
    viewModel.nodes[targetIndex].layoutSource = .manual

    #expect(viewModel.canReflowLayout)

    viewModel.reflowLayout()

    guard
      let sourceAfterReflow = viewModel.node("source-node"),
      let targetAfterReflow = viewModel.node("target-node")
    else {
      Issue.record("Expected live nodes after full manual reflow")
      return
    }

    #expect(sourceAfterReflow.position != manualSource)
    #expect(targetAfterReflow.position != manualTarget)
    #expect(sourceAfterReflow.layoutSource == .auto)
    #expect(targetAfterReflow.layoutSource == .auto)
    let bounds = viewModel.canvasContentBounds
    let leftWhitespace = bounds.minX
    let rightWhitespace = viewModel.canvasContentSize.width - bounds.maxX
    let topWhitespace = bounds.minY
    let bottomWhitespace = viewModel.canvasContentSize.height - bounds.maxY
    #expect(abs(leftWhitespace - rightWhitespace) <= 1)
    #expect(abs(topWhitespace - bottomWhitespace) <= 1)
    #expect(undoManager.canUndo)

    undoManager.undo()

    #expect(viewModel.node("source-node")?.position == manualSource)
    #expect(viewModel.node("target-node")?.position == manualTarget)
    #expect(viewModel.node("source-node")?.layoutSource == .manual)
    #expect(viewModel.node("target-node")?.layoutSource == .manual)
  }

  @Test("reflow requests viewport centering on apply and undo")
  func reflowRequestsViewportCenteringOnApplyAndUndo() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.load(document: overlappingReflowDocument(revision: 902), simulation: nil, audit: nil)

    guard
      let sourceIndex = viewModel.nodes.firstIndex(where: { $0.id == "source-node" }),
      let targetIndex = viewModel.nodes.firstIndex(where: { $0.id == "target-node" })
    else {
      Issue.record("Expected source and target nodes for viewport centering test")
      return
    }

    viewModel.nodes[sourceIndex].position = CGPoint(x: 1_040, y: 880)
    viewModel.nodes[sourceIndex].layoutSource = .manual
    viewModel.nodes[targetIndex].position = CGPoint(x: 720, y: 180)
    viewModel.nodes[targetIndex].layoutSource = .manual

    #expect(viewModel.consumeViewportCenteringRequest())
    #expect(!viewModel.hasPendingViewportCenteringRequest)

    viewModel.reflowLayout()

    #expect(viewModel.viewportCenteringBehavior == .document)
    #expect(viewModel.hasPendingViewportCenteringRequest)
    #expect(undoManager.canUndo)
    #expect(viewModel.consumeViewportCenteringRequest())
    #expect(!viewModel.hasPendingViewportCenteringRequest)

    undoManager.undo()

    #expect(viewModel.viewportCenteringBehavior == .document)
    #expect(viewModel.hasPendingViewportCenteringRequest)
  }

  @Test("second reflow is a no-op once the centered auto layout already matches")
  func secondReflowIsANoOpOnceCenteredAutoLayoutAlreadyMatches() {
    let viewModel = PolicyCanvasViewModel.sample()
    let undoManager = UndoManager()
    viewModel.attachUndoManager(undoManager)
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(revision: 907),
      simulation: nil,
      audit: nil
    )

    // Collapse the loaded layout into an overlapping pile so the first Reformat
    // has real work to do (auto-arrange + center). A layout that is already tidy
    // is left untouched - that path is covered by the seeded-layout reflow test.
    for index in viewModel.nodes.indices {
      viewModel.nodes[index].layoutSource = .manual
      viewModel.nodes[index].position = CGPoint(x: 60, y: 60)
    }

    #expect(viewModel.consumeViewportCenteringRequest())
    #expect(!viewModel.hasPendingViewportCenteringRequest)

    viewModel.reflowLayout()

    let positionsAfterFirstReflow = Dictionary(
      uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) }
    )
    let layoutSourcesAfterFirstReflow = Dictionary(
      uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.layoutSource) }
    )
    let routingHintsAfterFirstReflow = viewModel.routingHints
    let centeringGenerationAfterFirstReflow = viewModel.viewportCenteringGeneration

    #expect(viewModel.hasPendingViewportCenteringRequest)
    #expect(viewModel.consumeViewportCenteringRequest())
    #expect(!viewModel.hasPendingViewportCenteringRequest)

    viewModel.reflowLayout()

    let positionsAfterSecondReflow = Dictionary(
      uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) }
    )
    let layoutSourcesAfterSecondReflow = Dictionary(
      uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.layoutSource) }
    )

    #expect(positionsAfterSecondReflow == positionsAfterFirstReflow)
    #expect(layoutSourcesAfterSecondReflow == layoutSourcesAfterFirstReflow)
    #expect(viewModel.routingHints == routingHintsAfterFirstReflow)
    #expect(
      viewModel.viewportCenteringGeneration == centeringGenerationAfterFirstReflow
    )
    #expect(!viewModel.hasPendingViewportCenteringRequest)

    undoManager.undo()

    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .manual })
  }

  @Test("document viewport centering ignores the current selection")
  func documentViewportCenteringIgnoresTheCurrentSelection() async {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(revision: 905),
      simulation: nil,
      audit: nil
    )
    viewModel.selection = .node("action:router")

    let routeOutput = await PolicyCanvasRouteWorker(router: PolicyCanvasVisibilityRouter())
      .compute(
        input: PolicyCanvasRouteWorkerInput(
          nodes: viewModel.nodes,
          groups: viewModel.groups,
          edges: viewModel.edges,
          fontScale: 1,
          routingHints: viewModel.routingHints
        )
      )
    let viewportSize = CGSize(width: 1_440, height: 900)
    let selectionScrollPoint = policyCanvasViewportCenteringSelectionScrollPoint(
      behavior: .selectionIfPresent,
      selection: viewModel.selection,
      viewModel: viewModel,
      routeOutput: routeOutput,
      viewportSize: viewportSize,
      zoom: viewModel.zoom
    )
    let documentScrollPoint = policyCanvasViewportCenteringSelectionScrollPoint(
      behavior: .document,
      selection: viewModel.selection,
      viewModel: viewModel,
      routeOutput: routeOutput,
      viewportSize: viewportSize,
      zoom: viewModel.zoom
    )
    let initialScrollPoint = policyCanvasInitialViewportDocumentScrollPoint(
      visibleBounds: routeOutput.visibleBounds,
      viewportSize: viewportSize,
      zoom: viewModel.zoom
    )

    #expect(selectionScrollPoint != nil)
    #expect(documentScrollPoint == nil)
    #expect(selectionScrollPoint != initialScrollPoint)
  }

  @Test("Reformat keeps a tidy saved within-group order untouched")
  func fullManualReflowPreservesSavedWithinGroupOrder() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = pairedGroupOrderSeedDocument(revision: 903)
    viewModel.load(document: document, simulation: nil, audit: nil)

    // The saved layout places source-a below source-b (and sink-a below sink-b)
    // and loads as tidy trusted/manual coordinates - the same path the live
    // canvas takes for a saved policy. Reformat must keep that arrangement
    // verbatim instead of re-running the engine and reshuffling the rows, the
    // regression a user hits when an untouched saved layout scrambles on Reformat.
    let sourceABefore = viewModel.node("source-a")?.position
    let sourceBBefore = viewModel.node("source-b")?.position
    let sinkABefore = viewModel.node("sink-a")?.position
    let sinkBBefore = viewModel.node("sink-b")?.position

    #expect(sourceABefore?.y ?? .zero > sourceBBefore?.y ?? .zero)
    #expect(sinkABefore?.y ?? .zero > sinkBBefore?.y ?? .zero)
    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .manual })

    viewModel.reflowLayout()

    guard
      let sourceAAfter = viewModel.node("source-a"),
      let sourceBAfter = viewModel.node("source-b"),
      let sinkAAfter = viewModel.node("sink-a"),
      let sinkBAfter = viewModel.node("sink-b")
    else {
      Issue.record("Expected paired group nodes after full manual reflow")
      return
    }

    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .manual })
    #expect(sourceAAfter.position == sourceABefore)
    #expect(sourceBAfter.position == sourceBBefore)
    #expect(sinkAAfter.position == sinkABefore)
    #expect(sinkBAfter.position == sinkBBefore)
  }

  @Test("reflowed merge pass route stays simple after full manual reflow")
  func reflowedMergePassRouteStaysSimpleAfterFullManualReflow() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: PreviewFixtures.policyCanvasPipelineDocument(revision: 904),
      simulation: nil,
      audit: nil
    )

    for index in viewModel.nodes.indices {
      viewModel.nodes[index].layoutSource = .manual
    }

    viewModel.reflowLayout()

    let routes = policyCanvasDisplayedRoutes(
      viewModel: viewModel,
      edges: viewModel.edges,
      portAnchors: viewModel.portAnchors(for: viewModel.edges),
      router: PolicyCanvasVisibilityRouter()
    )
    guard let route = routes["edge:evidence-pass"] else {
      Issue.record("Expected merge-pass route after full manual reflow")
      return
    }

    let metrics = policyCanvasRouteMetrics(route)
    #expect(policyCanvasRouteSourceSide(route) == .trailing)
    #expect(policyCanvasRouteTargetSide(route) == .leading)
    #expect(
      metrics.bends <= 2,
      "edge:evidence-pass should stay visually direct after reflow; points: \(route.points)"
    )
    #expect(
      policyCanvasHorizontalBandPenalty(route) == 0,
      """
      edge:evidence-pass should not detour outside the source-target \
      horizontal band; points: \(route.points)
      """
    )
  }

  @Test(
    "full manual reflow recenters the preview policy and lowers the entry group off the top row")
  func fullManualReflowRecentersPreviewPolicyAndLowersEntryGroup() {
    let document = PreviewFixtures.policyCanvasPipelineDocument(revision: 906)
    let rawNodes = document.nodes.map { policyCanvasNode($0, layout: document.layout) }
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: document,
      simulation: nil,
      audit: nil
    )
    let originalPositions = Dictionary(uniqueKeysWithValues: rawNodes.map { ($0.id, $0.position) })
    for index in viewModel.nodes.indices {
      viewModel.nodes[index].layoutSource = .manual
    }

    viewModel.reflowLayout()

    let recenteredBounds = viewModel.canvasContentBounds
    let leftWhitespace = recenteredBounds.minX
    let rightWhitespace = viewModel.canvasContentSize.width - recenteredBounds.maxX
    let topWhitespace = recenteredBounds.minY
    let bottomWhitespace = viewModel.canvasContentSize.height - recenteredBounds.maxY
    let movedNodeCount = viewModel.nodes.reduce(into: 0) { count, node in
      guard let originalPosition = originalPositions[node.id] else {
        return
      }
      if hypot(node.position.x - originalPosition.x, node.position.y - originalPosition.y) >= 120 {
        count += 1
      }
    }
    guard let entryNode = viewModel.node("action:router") else {
      Issue.record("Expected action gate after full manual reflow")
      return
    }
    let entryFrame = policyCanvasNodeFrame(entryNode)

    #expect(abs(leftWhitespace - rightWhitespace) <= 1)
    #expect(abs(topWhitespace - bottomWhitespace) <= 1)
    #expect(movedNodeCount >= max(4, viewModel.nodes.count / 2))
    #expect(entryFrame.minY >= recenteredBounds.minY + PolicyCanvasLayout.gridSize)
  }

  @Test("forced reformat visibly rearranges the live saved dashboard policy layout")
  func forcedReformatVisiblyRearrangesTheLiveSavedDashboardPolicyLayout() {
    let viewModel = PolicyCanvasViewModel.sample()
    viewModel.load(
      document: liveSavedDefaultPolicyDocument(revision: 944),
      simulation: nil,
      audit: nil
    )

    let positionsBeforeReflow = Dictionary(
      uniqueKeysWithValues: viewModel.nodes.map { ($0.id, $0.position) }
    )
    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .manual })

    viewModel.reflowLayout(preserveManualAnchors: false, force: true)

    let movedNodeCount = viewModel.nodes.reduce(into: 0) { count, node in
      guard let originalPosition = positionsBeforeReflow[node.id] else {
        return
      }
      if hypot(node.position.x - originalPosition.x, node.position.y - originalPosition.y) >= 80 {
        count += 1
      }
    }

    #expect(movedNodeCount >= max(4, viewModel.nodes.count / 4))
    #expect(viewModel.nodes.allSatisfy { $0.layoutSource == .auto })
    #expect(viewModel.hasPendingViewportCenteringRequest)
  }

}
