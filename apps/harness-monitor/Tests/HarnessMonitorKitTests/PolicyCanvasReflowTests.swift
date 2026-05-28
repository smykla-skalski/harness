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
    var predictedNodes = viewModel.nodes
    var predictedGroups = viewModel.groups
    guard
      let predictedResult = policyCanvasAutomaticLayoutResult(
        nodes: predictedNodes,
        groups: predictedGroups,
        edges: viewModel.edges,
        mode: .explicitReflow(preserveManualAnchors: true)
      )
    else {
      Issue.record("Expected a predicted layout result for reflow test")
      return
    }
    let expectedRoutingHintsAfterReflow = applyPolicyCanvasLayoutResult(
      predictedResult,
      nodes: &predictedNodes,
      groups: &predictedGroups,
      centerInMinimumCanvas: false
    )
    let expectedEdgeAfterReflow = policyCanvasApplyingPreferredPortSides(
      viewModel.edges[edgeIndex],
      nodes: predictedNodes,
      preservesPinnedState: true
    )
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

    for index in viewModel.nodes.indices {
      viewModel.nodes[index].layoutSource = .manual
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
    let viewportCenteringGenerationAfterFirstReflow = viewModel.viewportCenteringGeneration

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
      viewModel.viewportCenteringGeneration == viewportCenteringGenerationAfterFirstReflow
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

  @Test("full manual reflow reseeds paired groups from graph order instead of manual geometry")
  func fullManualReflowReseedsPairedGroupsFromGraphOrder() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = pairedGroupOrderSeedDocument(revision: 903)
    viewModel.load(document: document, simulation: nil, audit: nil)

    let sourceABefore = viewModel.node("source-a")?.position
    let sourceBBefore = viewModel.node("source-b")?.position
    let sinkABefore = viewModel.node("sink-a")?.position
    let sinkBBefore = viewModel.node("sink-b")?.position

    #expect(sourceABefore?.y ?? .zero > sourceBBefore?.y ?? .zero)
    #expect(sinkABefore?.y ?? .zero > sinkBBefore?.y ?? .zero)

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

    #expect(sourceAAfter.layoutSource == .auto)
    #expect(sourceBAfter.layoutSource == .auto)
    #expect(sinkAAfter.layoutSource == .auto)
    #expect(sinkBAfter.layoutSource == .auto)
    #expect(sourceAAfter.position.y < sourceBAfter.position.y)
    #expect(sinkAAfter.position.y < sinkBAfter.position.y)
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
      "edge:evidence-pass should not detour outside the source-target horizontal band; points: \(route.points)"
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

  private func overlappingReflowDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "source-node",
          title: "Source",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "action_gate", actions: [.spawnAgent]),
          groupId: "group-source",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
          outputs: [TaskBoardPolicyPipelinePort(id: "out", title: "out")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "target-node",
          title: "Target",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "action_gate", actions: [.spawnAgent]),
          groupId: "group-target",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")]
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "source-target",
          fromNodeId: "source-node",
          fromPort: "out",
          toNodeId: "target-node",
          toPort: "in"
        )
      ],
      groups: [
        TaskBoardPolicyPipelineGroup(
          id: "group-source",
          title: "Source group",
          nodeIds: ["source-node"]
        ),
        TaskBoardPolicyPipelineGroup(
          id: "group-target",
          title: "Target group",
          nodeIds: ["target-node"]
        ),
      ],
      layout: TaskBoardPolicyPipelineLayout(
        nodes: [
          TaskBoardPolicyPipelineNodeLayout(nodeId: "source-node", x: 40, y: 60),
          TaskBoardPolicyPipelineNodeLayout(nodeId: "target-node", x: 40, y: 60),
        ]
      ),
      policyTraceIds: ["reflow-trace-\(revision)"]
    )
  }

  private func alternateSide(for side: PolicyCanvasPortSide?) -> PolicyCanvasPortSide {
    guard let side else {
      return .leading
    }
    return PolicyCanvasPortSide.allSides.first { $0 != side } ?? side
  }

  private func pairedGroupOrderSeedDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "source-a",
          title: "Source A",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "action_gate", actions: [.spawnAgent]),
          groupId: "group-source",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
          outputs: [TaskBoardPolicyPipelinePort(id: "out", title: "out")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "source-b",
          title: "Source B",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "action_gate", actions: [.spawnAgent]),
          groupId: "group-source",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
          outputs: [TaskBoardPolicyPipelinePort(id: "out", title: "out")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "sink-a",
          title: "Sink A",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "human_gate", actions: [.spawnAgent]),
          groupId: "group-target",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")]
        ),
        TaskBoardPolicyPipelineNode(
          id: "sink-b",
          title: "Sink B",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "human_gate", actions: [.spawnAgent]),
          groupId: "group-target",
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")]
        ),
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "edge:source-a",
          fromNodeId: "source-a",
          fromPort: "out",
          toNodeId: "sink-a",
          toPort: "in"
        ),
        TaskBoardPolicyPipelineEdge(
          id: "edge:source-b",
          fromNodeId: "source-b",
          fromPort: "out",
          toNodeId: "sink-b",
          toPort: "in"
        ),
      ],
      groups: [
        TaskBoardPolicyPipelineGroup(
          id: "group-source",
          title: "Source group",
          nodeIds: ["source-a", "source-b"]
        ),
        TaskBoardPolicyPipelineGroup(
          id: "group-target",
          title: "Target group",
          nodeIds: ["sink-a", "sink-b"]
        ),
      ],
      layout: TaskBoardPolicyPipelineLayout(
        nodes: [
          TaskBoardPolicyPipelineNodeLayout(
            nodeId: "source-a",
            x: 80,
            y: 300,
            source: .manual
          ),
          TaskBoardPolicyPipelineNodeLayout(
            nodeId: "source-b",
            x: 80,
            y: 60,
            source: .manual
          ),
          TaskBoardPolicyPipelineNodeLayout(
            nodeId: "sink-a",
            x: 520,
            y: 300,
            source: .manual
          ),
          TaskBoardPolicyPipelineNodeLayout(
            nodeId: "sink-b",
            x: 520,
            y: 60,
            source: .manual
          ),
        ]
      ),
      policyTraceIds: ["paired-order-seed-\(revision)"]
    )
  }
}
