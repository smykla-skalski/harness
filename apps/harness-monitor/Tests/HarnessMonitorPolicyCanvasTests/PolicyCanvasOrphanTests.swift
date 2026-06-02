import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas document orphans")
@MainActor
struct PolicyCanvasOrphanTests {
  @Test("load tolerates group nodeIds that point at missing nodes")
  func loadTolerantOfMissingGroupMembers() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = makeOrphanGroupDocument()

    viewModel.load(document: document, simulation: nil, audit: nil)

    // Sanity: known node landed in nodes; missing id did not.
    #expect(viewModel.nodes.contains { $0.id == "node-real" })
    #expect(!viewModel.nodes.contains { $0.id == "node-missing" })

    // Group is present even though one referenced id is absent.
    let group = viewModel.group("group-orphan")
    #expect(group != nil)
    #expect(group?.title == "Orphan group")

    // The known node was attached to the group via assignGroupMembership.
    #expect(viewModel.nodes(in: "group-orphan").map(\.id) == ["node-real"])
  }

  @Test("orphan group member is dropped on round-trip export")
  func orphanGroupMemberDroppedOnExport() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = makeOrphanGroupDocument()

    viewModel.load(document: document, simulation: nil, audit: nil)
    let exported = viewModel.exportDocument()

    let exportedGroup = exported.groups.first { $0.id == "group-orphan" }
    #expect(exportedGroup != nil)
    // Current behavior: exportDocument rebuilds nodeIds from current
    // node->groupID membership, so missing ids do not survive round-trip.
    #expect(exportedGroup?.nodeIds == ["node-real"])
    #expect(exportedGroup?.nodeIds.contains("node-missing") == false)
  }

  @Test("orphan edge endpoints are dropped on load and export")
  func orphanEdgeIsDroppedOnRoundTrip() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = makeOrphanEdgeDocument()

    viewModel.load(document: document, simulation: nil, audit: nil)

    let canvasEdge = viewModel.edges.first { $0.id == "edge-dead-target" }
    #expect(canvasEdge == nil)
    #expect(viewModel.node("node-missing") == nil)

    let exported = viewModel.exportDocument()
    let exportedEdge = exported.edges.first { $0.id == "edge-dead-target" }
    #expect(exportedEdge == nil)
  }

  // MARK: - Helpers

  /// A document where a group references one real node and one missing id.
  private func makeOrphanGroupDocument() -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: 7,
      mode: .draft,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "node-real",
          title: "Real",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "action_gate", actions: [.spawnAgent]),
          inputs: [TaskBoardPolicyPipelinePort(id: "in", title: "in")],
          outputs: [TaskBoardPolicyPipelinePort(id: "out", title: "out")]
        )
      ],
      edges: [],
      groups: [
        TaskBoardPolicyPipelineGroup(
          id: "group-orphan",
          title: "Orphan group",
          nodeIds: ["node-real", "node-missing"]
        )
      ],
      layout: TaskBoardPolicyPipelineLayout(
        nodes: [TaskBoardPolicyPipelineNodeLayout(nodeId: "node-real", x: 80, y: 80)]
      )
    )
  }

  /// A document with one valid node plus an edge whose target node id does
  /// not appear in nodes.
  private func makeOrphanEdgeDocument() -> TaskBoardPolicyPipelineDocument {
    TaskBoardPolicyPipelineDocument(
      schemaVersion: 2,
      revision: 8,
      mode: .draft,
      nodes: [
        TaskBoardPolicyPipelineNode(
          id: "node-real",
          title: "Real",
          kind: TaskBoardPolicyPipelineNodeKind(kind: "trigger", workflow: "default-task"),
          inputs: [],
          outputs: [TaskBoardPolicyPipelinePort(id: "out", title: "out")]
        )
      ],
      edges: [
        TaskBoardPolicyPipelineEdge(
          id: "edge-dead-target",
          fromNodeId: "node-real",
          fromPort: "out",
          toNodeId: "node-missing",
          toPort: "in"
        )
      ],
      groups: [],
      layout: TaskBoardPolicyPipelineLayout(
        nodes: [TaskBoardPolicyPipelineNodeLayout(nodeId: "node-real", x: 60, y: 80)]
      )
    )
  }
}
