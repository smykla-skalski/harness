import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms
import HarnessMonitorPolicyModels

extension PolicyCanvasLocalValidationTests {
  struct OrphanNodeSpec {
    let id: String
    let groupID: String?
  }

  /// Build a canvas with the given node id pairs connected by edges. Each
  /// node has an `out` output port and an `in` input port so edge endpoints
  /// resolve cleanly. Cycle detection works only on node ids, so the port
  /// detail is incidental.
  func makeCycleCanvas(edges: [(String, String)]) -> PolicyCanvasViewModel {
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

  func makeOrphanCanvas(
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
  /// terminal, joined by a single edge. The terminal's decision is derived
  /// from `ruleId` (a name containing "deny" denies, otherwise allows) so the
  /// error-into-allow validator - which now keys on the supervisor decision -
  /// has ground truth to match against; the edge's `condition` decides its
  /// kind via the heuristic (e.g. `"evidence_failure"` -> `.error`).
  func makeAllowMismatchCanvas(
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
    let denies = ruleId.contains("deny")
    allow.policyKind = .supervisorRule(
      decision: denies ? .deny : .allow,
      reasonCodes: [denies ? .checksNotGreen : .defaultAllow]
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
  func makeLabeledCanvas(nodes: [(String, String)]) -> PolicyCanvasViewModel {
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

  /// Drive the off-main validation worker and apply its presentation onto the
  /// view model, mirroring the view's `rebuildValidation()` path. The view
  /// model's `allValidationIssues`/severity maps read the worker-applied
  /// presentation, so tests must run this before asserting on those readers.
  func applyValidationPresentation(_ viewModel: PolicyCanvasViewModel) async {
    let worker = PolicyCanvasValidationWorker()
    let output = await worker.compute(
      input: PolicyCanvasValidationWorkerInput(
        nodes: viewModel.nodes,
        edges: viewModel.edges,
        daemonIssues: viewModel.daemonValidationIssues
      )
    )
    viewModel.applyValidationPresentation(output)
  }
}
