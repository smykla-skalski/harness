import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

struct PolicyCanvasReflowPrediction {
  let routingHints: PolicyCanvasLayoutRoutingHints?
  let edge: PolicyCanvasEdge
}

extension PolicyCanvasReflowTests {
  /// Mirrors the engine path `reflowLayout()` takes so a test can compare the
  /// live result against the predicted routing hints and edge port sides.
  func predictedReflow(
    viewModel: PolicyCanvasViewModel,
    edgeIndex: Int
  ) -> PolicyCanvasReflowPrediction? {
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
      return nil
    }
    let routingHints = applyPolicyCanvasLayoutResult(
      predictedResult,
      nodes: &predictedNodes,
      groups: &predictedGroups,
      centerInMinimumCanvas: false
    )
    let edge = policyCanvasApplyingPreferredPortSides(
      viewModel.edges[edgeIndex],
      nodes: predictedNodes,
      preservesPinnedState: true
    )
    return PolicyCanvasReflowPrediction(routingHints: routingHints, edge: edge)
  }

  func overlappingReflowDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
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

  func alternateSide(for side: PolicyCanvasPortSide?) -> PolicyCanvasPortSide {
    guard let side else {
      return .leading
    }
    return PolicyCanvasPortSide.allSides.first { $0 != side } ?? side
  }

  func pairedGroupOrderSeedDocument(revision: UInt64) -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: pairedGroupOrderSeedNodes(),
      edges: pairedGroupOrderSeedEdges(),
      groups: pairedGroupOrderSeedGroups(),
      layout: pairedGroupOrderSeedLayout(),
      policyTraceIds: ["paired-order-seed-\(revision)"]
    )
  }

  private func pairedGroupOrderSeedNodes() -> [TaskBoardPolicyPipelineNode] {
    [
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
    ]
  }

  private func pairedGroupOrderSeedEdges() -> [TaskBoardPolicyPipelineEdge] {
    [
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
    ]
  }

  private func pairedGroupOrderSeedGroups() -> [TaskBoardPolicyPipelineGroup] {
    [
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
    ]
  }

  private func pairedGroupOrderSeedLayout() -> TaskBoardPolicyPipelineLayout {
    TaskBoardPolicyPipelineLayout(
      nodes: [
        TaskBoardPolicyPipelineNodeLayout(nodeId: "source-a", x: 80, y: 300, source: .manual),
        TaskBoardPolicyPipelineNodeLayout(nodeId: "source-b", x: 80, y: 60, source: .manual),
        TaskBoardPolicyPipelineNodeLayout(nodeId: "sink-a", x: 520, y: 300, source: .manual),
        TaskBoardPolicyPipelineNodeLayout(nodeId: "sink-b", x: 520, y: 60, source: .manual),
      ]
    )
  }
}
