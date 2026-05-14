import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas local validation")
@MainActor
struct PolicyCanvasLocalValidationTests {
  @Test("two-node cycle A→B→A is flagged with both nodes named")
  func twoNodeCycleIsDetected() {
    let viewModel = makeCycleCanvas(edges: [
      ("a", "b"),
      ("b", "a"),
    ])

    let issues = viewModel.validateGraph()
    let cycle = issues.first { $0.code == "cycle" }

    #expect(cycle != nil)
    let cycleNodes = Set(cycle?.nodeIds ?? [])
    #expect(cycleNodes.isSuperset(of: ["a", "b"]))
  }

  @Test("three-node cycle A→B→C→A is flagged")
  func threeNodeCycleIsDetected() {
    let viewModel = makeCycleCanvas(edges: [
      ("a", "b"),
      ("b", "c"),
      ("c", "a"),
    ])

    let issues = viewModel.validateGraph()
    let cycle = issues.first { $0.code == "cycle" }

    #expect(cycle != nil)
    let cycleNodes = Set(cycle?.nodeIds ?? [])
    #expect(cycleNodes.isSuperset(of: ["a", "b", "c"]))
  }

  @Test("self-loop A→A counts as a cycle")
  func selfLoopIsDetected() {
    let viewModel = makeCycleCanvas(edges: [
      ("a", "a")
    ])

    let issues = viewModel.validateGraph()
    let cycle = issues.first { $0.code == "cycle" }

    #expect(cycle != nil)
    #expect(cycle?.nodeIds.contains("a") == true)
  }

  @Test("acyclic tree A→B→C is not a cycle")
  func acyclicTreeIsClean() {
    let viewModel = makeCycleCanvas(edges: [
      ("a", "b"),
      ("b", "c"),
    ])

    let issues = viewModel.validateGraph()
    let cycle = issues.first { $0.code == "cycle" }

    #expect(cycle == nil)
  }

  @Test("diamond graph (A→B, A→C, B→D, C→D) is not a cycle")
  func diamondGraphIsClean() {
    let viewModel = makeCycleCanvas(edges: [
      ("a", "b"),
      ("a", "c"),
      ("b", "d"),
      ("c", "d"),
    ])

    let issues = viewModel.validateGraph()
    let cycle = issues.first { $0.code == "cycle" }

    #expect(cycle == nil)
  }

  @Test("orphan node has no edges and no group is flagged")
  func orphanNodeIsDetected() {
    let viewModel = makeOrphanCanvas(
      nodes: [
        OrphanNodeSpec(id: "connected-1", groupID: nil),
        OrphanNodeSpec(id: "connected-2", groupID: nil),
        OrphanNodeSpec(id: "alone", groupID: nil),
      ],
      edges: [
        ("connected-1", "connected-2")
      ]
    )

    let issues = viewModel.validateGraph()
    let orphans = issues.filter { $0.code == "orphan_node" }

    #expect(orphans.count == 1)
    #expect(orphans.first?.nodeId == "alone")
  }

  @Test("node in a group is not an orphan even without edges")
  func nodeInGroupIsNotOrphan() {
    let viewModel = makeOrphanCanvas(
      nodes: [
        OrphanNodeSpec(id: "grouped", groupID: "g1"),
        OrphanNodeSpec(id: "alone", groupID: nil),
      ],
      edges: []
    )

    let issues = viewModel.validateGraph()
    let orphans = issues.filter { $0.code == "orphan_node" }
    let flagged = orphans.compactMap(\.nodeId)

    #expect(flagged == ["alone"])
    #expect(!flagged.contains("grouped"))
  }

  @Test("node with only incoming edge is not an orphan")
  func incomingEdgeAvoidsOrphan() {
    let viewModel = makeOrphanCanvas(
      nodes: [
        OrphanNodeSpec(id: "source", groupID: nil),
        OrphanNodeSpec(id: "sink", groupID: nil),
      ],
      edges: [
        ("source", "sink")
      ]
    )

    let issues = viewModel.validateGraph()
    let orphans = issues.filter { $0.code == "orphan_node" }

    #expect(orphans.isEmpty)
  }

  @Test("clean graph has no validation issues")
  func cleanGraphHasNoIssues() {
    let viewModel = makeOrphanCanvas(
      nodes: [
        OrphanNodeSpec(id: "a", groupID: "g1"),
        OrphanNodeSpec(id: "b", groupID: "g1"),
      ],
      edges: [
        ("a", "b")
      ]
    )

    let issues = viewModel.validateGraph()

    #expect(issues.isEmpty)
  }

  @Test("multiple disconnected components stay clean when each has an edge")
  func multipleAcyclicComponentsAreClean() {
    let viewModel = makeOrphanCanvas(
      nodes: [
        OrphanNodeSpec(id: "a1", groupID: nil),
        OrphanNodeSpec(id: "a2", groupID: nil),
        OrphanNodeSpec(id: "b1", groupID: nil),
        OrphanNodeSpec(id: "b2", groupID: nil),
      ],
      edges: [
        ("a1", "a2"),
        ("b1", "b2"),
      ]
    )

    let issues = viewModel.validateGraph()

    #expect(issues.isEmpty)
  }

  @Test("local cycles surface in allValidationIssues alongside daemon issues")
  func localCyclesSurfaceInAllIssues() {
    let viewModel = makeCycleCanvas(edges: [
      ("a", "b"),
      ("b", "a"),
    ])
    viewModel.latestSimulation = TaskBoardPolicyPipelineSimulationResult(
      revision: 1,
      traceId: "trace-test",
      simulatedAt: "2026-05-14T00:00:00Z",
      succeeded: false,
      validation: TaskBoardPolicyPipelineValidation(
        isValid: false,
        issues: [
          TaskBoardPolicyPipelineValidationIssue(
            code: "dangling_edge",
            message: "edge points at missing port",
            edgeId: "edge-aa"
          )
        ]
      )
    )

    let resolved = viewModel.allValidationIssues
    let codes = resolved.map(\.issue.code)

    #expect(codes.contains("cycle"))
    #expect(codes.contains("dangling_edge"))
  }

  // MARK: - Helpers

  private struct OrphanNodeSpec {
    let id: String
    let groupID: String?
  }

  /// Build a canvas with the given node id pairs connected by edges. Each
  /// node has an `out` output port and an `in` input port so edge endpoints
  /// resolve cleanly. Cycle detection works only on node ids, so the port
  /// detail is incidental.
  private func makeCycleCanvas(edges: [(String, String)]) -> PolicyCanvasViewModel {
    var ids = Set<String>()
    for (from, to) in edges {
      ids.insert(from)
      ids.insert(to)
    }
    let nodes = ids.sorted().map { id in
      PolicyCanvasNode(
        id: id,
        title: id,
        kind: .source,
        position: .zero
      )
    }
    let canvasEdges = edges.enumerated().map { offset, pair in
      PolicyCanvasEdge(
        id: "edge-\(pair.0)-\(pair.1)-\(offset)",
        source: PolicyCanvasPortEndpoint(nodeID: pair.0, portID: "out", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: pair.1, portID: "in", kind: .input),
        label: "\(pair.0)→\(pair.1)"
      )
    }
    return PolicyCanvasViewModel(
      nodes: nodes,
      groups: [],
      edges: canvasEdges,
      selection: nil,
      zoom: 1
    )
  }

  private func makeOrphanCanvas(
    nodes: [OrphanNodeSpec],
    edges: [(String, String)]
  ) -> PolicyCanvasViewModel {
    let canvasNodes = nodes.map { spec -> PolicyCanvasNode in
      var node = PolicyCanvasNode(
        id: spec.id,
        title: spec.id,
        kind: .source,
        position: .zero
      )
      node.groupID = spec.groupID
      return node
    }
    let groupIDs = Set(nodes.compactMap(\.groupID))
    let canvasGroups = groupIDs.map { groupID in
      PolicyCanvasGroup(
        id: groupID,
        title: groupID,
        frame: CGRect(x: 0, y: 0, width: 200, height: 200),
        tone: .intake
      )
    }
    let canvasEdges = edges.enumerated().map { offset, pair in
      PolicyCanvasEdge(
        id: "edge-\(pair.0)-\(pair.1)-\(offset)",
        source: PolicyCanvasPortEndpoint(nodeID: pair.0, portID: "out", kind: .output),
        target: PolicyCanvasPortEndpoint(nodeID: pair.1, portID: "in", kind: .input),
        label: "\(pair.0)→\(pair.1)"
      )
    }
    return PolicyCanvasViewModel(
      nodes: canvasNodes,
      groups: canvasGroups,
      edges: canvasEdges,
      selection: nil,
      zoom: 1
    )
  }
}
