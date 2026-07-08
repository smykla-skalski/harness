import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

/// Wave 3M P51 follow-up: locks document round-trip stability across multiple
/// export → applyDocument cycles, and locks the sanity baseline (clean
/// document round-trips with identical ids). Sibling to wave 1C's
/// PolicyCanvasOrphanTests which covers single-pass orphan-group + orphan-edge
/// import behaviour — this file fills the multi-cycle stability gap.
@Suite("Policy canvas document round-trip — orphans + stability")
@MainActor
struct PolicyCanvasDocumentRoundTripOrphansTests {
  @Test("clean document export then applyDocument preserves node and edge ids")
  func cleanRoundTripPreservesNodeAndEdgeIds() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = makeCleanDocument(revision: 5)

    viewModel.load(document: document, simulation: nil, audit: nil)
    let beforeNodeIds = viewModel.nodes.map(\.id).sorted()
    let beforeEdgeIds = viewModel.edges.map(\.id).sorted()
    let beforeGroupIds = viewModel.groups.map(\.id).sorted()

    let exported = viewModel.exportDocument()
    // Same VM round-trips through the export, then applyDocument-ing it back
    // must not introduce or drop ids. A second VM consumes the export so the
    // first VM's transient state is not the source of survival.
    let secondVM = PolicyCanvasViewModel.sample()
    secondVM.applyDocument(document: exported, simulation: nil, audit: nil)

    #expect(secondVM.nodes.map(\.id).sorted() == beforeNodeIds)
    #expect(secondVM.edges.map(\.id).sorted() == beforeEdgeIds)
    #expect(secondVM.groups.map(\.id).sorted() == beforeGroupIds)
  }

  @Test("two consecutive round-trips do not introduce id drift")
  func twoRoundTripsStable() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = makeCleanDocument(revision: 7)

    viewModel.load(document: document, simulation: nil, audit: nil)
    let firstExport = viewModel.exportDocument()
    let firstNodeIds = firstExport.nodes.map(\.id).sorted()
    let firstEdgeIds = firstExport.edges.map(\.id).sorted()
    let firstGroupIds = firstExport.groups.map(\.id).sorted()

    let secondVM = PolicyCanvasViewModel.sample()
    secondVM.applyDocument(document: firstExport, simulation: nil, audit: nil)
    let secondExport = secondVM.exportDocument()

    #expect(secondExport.nodes.map(\.id).sorted() == firstNodeIds)
    #expect(secondExport.edges.map(\.id).sorted() == firstEdgeIds)
    #expect(secondExport.groups.map(\.id).sorted() == firstGroupIds)
  }

  @Test("orphan group member id is dropped on first export and stays dropped")
  func orphanGroupMemberStableAcrossRoundTrips() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = makeOrphanGroupDocument(revision: 9)

    viewModel.load(document: document, simulation: nil, audit: nil)
    let firstExport = viewModel.exportDocument()
    let firstGroup = firstExport.groups.first { $0.id == "group-orphan" }
    #expect(firstGroup?.nodeIds == ["node-real"])

    let secondVM = PolicyCanvasViewModel.sample()
    secondVM.applyDocument(document: firstExport, simulation: nil, audit: nil)
    let secondExport = secondVM.exportDocument()
    let secondGroup = secondExport.groups.first { $0.id == "group-orphan" }

    #expect(secondGroup?.nodeIds == ["node-real"])
    #expect(secondGroup?.nodeIds.contains("node-missing") == false)
  }

  @Test("orphan edge endpoint is dropped across two round-trips")
  func orphanEdgeDroppedAcrossRoundTrips() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = makeOrphanEdgeDocument(revision: 11)

    viewModel.load(document: document, simulation: nil, audit: nil)
    let firstExport = viewModel.exportDocument()
    let firstEdge = firstExport.edges.first { $0.id == "edge-dead-target" }
    #expect(firstEdge == nil)

    let secondVM = PolicyCanvasViewModel.sample()
    secondVM.applyDocument(document: firstExport, simulation: nil, audit: nil)
    let secondExport = secondVM.exportDocument()
    let secondEdge = secondExport.edges.first { $0.id == "edge-dead-target" }

    #expect(secondEdge == nil)
  }

  @Test("a node in nodes but not in any group's nodeIds round-trips as ungrouped")
  func ungroupedNodeStable() {
    let viewModel = PolicyCanvasViewModel.sample()
    let document = makeUngroupedNodeDocument(revision: 13)

    viewModel.load(document: document, simulation: nil, audit: nil)
    let ungrouped = viewModel.node("node-loose")
    #expect(ungrouped != nil)
    #expect(ungrouped?.groupID == nil)

    let exported = viewModel.exportDocument()
    let exportedNode = exported.nodes.first { $0.id == "node-loose" }
    let exportedGroupMembership = exported.groups.flatMap(\.nodeIds)

    #expect(exportedNode != nil)
    #expect(exportedGroupMembership.contains("node-loose") == false)
  }

  // MARK: - Fixtures

  /// A small document with one group, two nodes both in the group, and one
  /// edge between them. No orphans — used as the clean-baseline harness for
  /// stability tests.
  private func makeCleanDocument(revision: UInt64) -> PolicyPipelineDocument {
    PolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        PolicyPipelineNode(
          id: "node-alpha",
          title: "Alpha",
          kind: .trigger(workflow: "default-task"),
          groupId: "group-clean",
          inputs: [],
          outputs: [PolicyPipelinePort(id: "out", title: "out")]
        ),
        PolicyPipelineNode(
          id: "node-beta",
          title: "Beta",
          kind: .actionGate(actions: [.spawnAgent]),
          groupId: "group-clean",
          inputs: [PolicyPipelinePort(id: "in", title: "in")],
          outputs: [PolicyPipelinePort(id: "default", title: "default")]
        ),
      ],
      edges: [
        PolicyPipelineEdge(
          id: "edge-alpha-beta",
          fromNodeId: "node-alpha",
          fromPort: "out",
          toNodeId: "node-beta",
          toPort: "in"
        )
      ],
      groups: [
        PolicyPipelineGroup(
          id: "group-clean",
          title: "Clean group",
          nodeIds: ["node-alpha", "node-beta"]
        )
      ],
      layout: PolicyPipelineLayout(
        nodes: [
          PolicyPipelineNodeLayout(nodeId: "node-alpha", x: 40, y: 60),
          PolicyPipelineNodeLayout(nodeId: "node-beta", x: 320, y: 60),
        ]
      )
    )
  }

  /// A document where a group references one real node and one missing id.
  /// Same shape as wave 1C's PolicyCanvasOrphanTests fixture so multi-pass
  /// stability tests use a familiar baseline.
  private func makeOrphanGroupDocument(revision: UInt64) -> PolicyPipelineDocument {
    PolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        PolicyPipelineNode(
          id: "node-real",
          title: "Real",
          kind: .actionGate(actions: [.spawnAgent]),
          inputs: [PolicyPipelinePort(id: "in", title: "in")],
          outputs: [PolicyPipelinePort(id: "out", title: "out")]
        )
      ],
      edges: [],
      groups: [
        PolicyPipelineGroup(
          id: "group-orphan",
          title: "Orphan group",
          nodeIds: ["node-real", "node-missing"]
        )
      ],
      layout: PolicyPipelineLayout(
        nodes: [PolicyPipelineNodeLayout(nodeId: "node-real", x: 80, y: 80)]
      )
    )
  }

  /// A document with one valid node plus an edge whose target node id does
  /// not appear in nodes.
  private func makeOrphanEdgeDocument(revision: UInt64) -> PolicyPipelineDocument {
    PolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        PolicyPipelineNode(
          id: "node-real",
          title: "Real",
          kind: .trigger(workflow: "default-task"),
          inputs: [],
          outputs: [PolicyPipelinePort(id: "out", title: "out")]
        )
      ],
      edges: [
        PolicyPipelineEdge(
          id: "edge-dead-target",
          fromNodeId: "node-real",
          fromPort: "out",
          toNodeId: "node-missing",
          toPort: "in"
        )
      ],
      groups: [],
      layout: PolicyPipelineLayout(
        nodes: [PolicyPipelineNodeLayout(nodeId: "node-real", x: 60, y: 80)]
      )
    )
  }

  /// A document with a node that is not referenced by any group's nodeIds.
  /// The mapping layer treats it as ungrouped and exportDocument should not
  /// magically attach it.
  private func makeUngroupedNodeDocument(revision: UInt64) -> PolicyPipelineDocument {
    PolicyPipelineDocument(
      schemaVersion: 2,
      revision: revision,
      mode: .draft,
      nodes: [
        PolicyPipelineNode(
          id: "node-grouped",
          title: "Grouped",
          kind: .trigger(workflow: "default-task"),
          groupId: "group-anchor",
          inputs: [],
          outputs: [PolicyPipelinePort(id: "out", title: "out")]
        ),
        PolicyPipelineNode(
          id: "node-loose",
          title: "Loose",
          kind: .actionGate(actions: [.spawnAgent]),
          inputs: [PolicyPipelinePort(id: "in", title: "in")],
          outputs: []
        ),
      ],
      edges: [],
      groups: [
        PolicyPipelineGroup(
          id: "group-anchor",
          title: "Anchor group",
          nodeIds: ["node-grouped"]
        )
      ],
      layout: PolicyPipelineLayout(
        nodes: [
          PolicyPipelineNodeLayout(nodeId: "node-grouped", x: 40, y: 60),
          PolicyPipelineNodeLayout(nodeId: "node-loose", x: 400, y: 60),
        ]
      )
    )
  }
}
