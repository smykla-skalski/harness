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

  @Test("duplicate node titles are flagged with the matched ids")
  func duplicateTitlesAreFlagged() {
    let viewModel = makeLabeledCanvas(nodes: [
      ("n1", "action in"),
      ("n2", "action in"),
      ("n3", "evidence pass"),
      ("n4", "action in"),
    ])

    let issues = viewModel.validateGraph()
    let dupes = issues.filter { $0.code == "duplicate_label" }

    #expect(dupes.count == 1)
    let nodeIds = Set(dupes.first?.nodeIds ?? [])
    #expect(nodeIds == ["n1", "n2", "n4"])
    let message = dupes.first?.message ?? ""
    #expect(message.contains("action in"))
    #expect(message.contains("3"))
  }

  @Test("unique titles produce no duplicate_label issues")
  func uniqueTitlesProduceNoIssue() {
    let viewModel = makeLabeledCanvas(nodes: [
      ("n1", "intake"),
      ("n2", "decision"),
      ("n3", "outcome"),
    ])

    let codes = viewModel.validateGraph().map(\.code)
    #expect(!codes.contains("duplicate_label"))
  }

  @Test("empty / whitespace titles do not surface as duplicates")
  func emptyTitleDuplicatesIgnored() {
    let viewModel = makeLabeledCanvas(nodes: [
      ("n1", ""),
      ("n2", "   "),
      ("n3", ""),
    ])

    let codes = viewModel.validateGraph().map(\.code)
    #expect(!codes.contains("duplicate_label"))
  }

  @Test("error edge into a default-allow supervisor rule is flagged")
  func errorIntoDefaultAllowFlagged() {
    let viewModel = makeAllowMismatchCanvas(
      ruleId: "default-allow",
      edgeCondition: "evidence_failure"
    )

    let issues = viewModel.validateGraph()
    let mismatch = issues.first { $0.code == "error_into_allow" }

    #expect(mismatch != nil)
    #expect(mismatch?.edgeId == "e")
    #expect(mismatch?.nodeId == "allow")
  }

  @Test("control edge into the same default-allow target is ignored")
  func controlIntoAllowIgnored() {
    let viewModel = makeAllowMismatchCanvas(
      ruleId: "default-allow",
      edgeCondition: "manual_approval"
    )

    let codes = viewModel.validateGraph().map(\.code)
    #expect(!codes.contains("error_into_allow"))
  }

  @Test("error edge into a deny terminal is ignored")
  func errorIntoDenyIgnored() {
    let viewModel = makeAllowMismatchCanvas(
      ruleId: "merge-deny",
      edgeCondition: "evidence_failure"
    )

    let codes = viewModel.validateGraph().map(\.code)
    #expect(!codes.contains("error_into_allow"))
  }

  @Test("multiple duplicate groups land in alphabetical title order")
  func duplicateGroupsSortedByTitle() {
    let viewModel = makeLabeledCanvas(nodes: [
      ("n1", "zeta"),
      ("n2", "zeta"),
      ("n3", "alpha"),
      ("n4", "alpha"),
    ])

    let messages = viewModel.validateGraph()
      .filter { $0.code == "duplicate_label" }
      .map(\.message)
    #expect(messages.count == 2)
    #expect(messages[0].contains("alpha"))
    #expect(messages[1].contains("zeta"))
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

  /// Build a canvas with one source node and one supervisor-rule
  /// terminal, joined by a single edge. The terminal carries the given
  /// `ruleId` so the error-into-allow validator has structured ground
  /// truth to match against, and the edge's `condition` decides its
  /// kind via the heuristic (e.g. `"evidence_failure"` -> `.error`).
  private func makeAllowMismatchCanvas(
    ruleId: String,
    edgeCondition: String
  ) -> PolicyCanvasViewModel {
    var source = PolicyCanvasNode(
      id: "src",
      title: "source",
      kind: .source,
      position: .zero
    )
    source.outputPorts = [
      PolicyCanvasPort(id: "out", title: "out", kind: .output)
    ]
    var allow = PolicyCanvasNode(
      id: "allow",
      title: "supervisor:\(ruleId)",
      kind: .decision,
      position: CGPoint(x: 400, y: 0)
    )
    allow.inputPorts = [
      PolicyCanvasPort(id: "in", title: "in", kind: .input)
    ]
    allow.policyKind = TaskBoardPolicyPipelineNodeKind(
      kind: "supervisor_rule",
      ruleId: ruleId
    )
    let edge = PolicyCanvasEdge(
      id: "e",
      source: PolicyCanvasPortEndpoint(nodeID: "src", portID: "out", kind: .output),
      target: PolicyCanvasPortEndpoint(nodeID: "allow", portID: "in", kind: .input),
      label: "",
      condition: edgeCondition
    )
    return PolicyCanvasViewModel(
      nodes: [source, allow],
      groups: [],
      edges: [edge],
      selection: nil,
      zoom: 1
    )
  }

  /// Build a canvas with explicit `(id, title)` pairs so the
  /// duplicate-label validator has a stable fixture. No edges, no
  /// groups - those are exercised separately by `makeCycleCanvas` and
  /// `makeOrphanCanvas`. The duplicate-label rule operates over node
  /// titles only, so a bare node list is the minimum sufficient
  /// fixture.
  private func makeLabeledCanvas(nodes: [(String, String)]) -> PolicyCanvasViewModel {
    let canvasNodes = nodes.map { id, title in
      PolicyCanvasNode(
        id: id,
        title: title,
        kind: .source,
        position: .zero
      )
    }
    return PolicyCanvasViewModel(
      nodes: canvasNodes,
      groups: [],
      edges: [],
      selection: nil,
      zoom: 1
    )
  }
}
