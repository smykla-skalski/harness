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
    var predictedNodes = viewModel.nodes
    var predictedGroups = viewModel.groups
    guard let predictedResult = policyCanvasAutomaticLayoutResult(
      nodes: predictedNodes,
      groups: predictedGroups,
      edges: viewModel.edges,
      mode: .explicitReflow(preserveManualAnchors: true)
    ) else {
      Issue.record("Expected a predicted layout result for reflow test")
      return
    }
    applyPolicyCanvasLayoutResult(
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
    #expect(undoManager.canUndo)

    undoManager.undo()

    #expect(viewModel.node("source-node")?.position == manualSource)
    #expect(viewModel.node("target-node")?.position == manualTarget)
    #expect(viewModel.node("source-node")?.layoutSource == .manual)
    #expect(viewModel.node("target-node")?.layoutSource == .manual)
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
        )
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
}
