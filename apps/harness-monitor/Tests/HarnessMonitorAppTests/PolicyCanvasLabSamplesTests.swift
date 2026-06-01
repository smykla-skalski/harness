import HarnessMonitorKit
import Testing

@testable import HarnessMonitor
@testable import HarnessMonitorUIPreviewable

/// Producer guard for the Policy Canvas Lab sample picker: every named sample
/// must be a valid graph the picker can render. Builds each sample and asserts
/// non-empty node/edge/group counts, unique node ids, and that every edge
/// endpoint resolves to a real node and a port that node actually declares.
@Suite("Policy canvas lab samples")
struct PolicyCanvasLabSamplesTests {
  /// Minimum node / edge / group counts expected per sample id. Guards against
  /// a sample silently collapsing to a trivial graph.
  private static let minimumCounts: [String: PolicyCanvasLabSampleMinimumCounts] = [
    "minimal": PolicyCanvasLabSampleMinimumCounts(nodes: 2, edges: 1, groups: 1),
    "linear": PolicyCanvasLabSampleMinimumCounts(nodes: 6, edges: 5, groups: 3),
    "branching": PolicyCanvasLabSampleMinimumCounts(nodes: 9, edges: 10, groups: 3),
    "default-like": PolicyCanvasLabSampleMinimumCounts(nodes: 16, edges: 21, groups: 3),
    "real-default": PolicyCanvasLabSampleMinimumCounts(nodes: 18, edges: 22, groups: 3),
    "multi-group": PolicyCanvasLabSampleMinimumCounts(nodes: 14, edges: 21, groups: 4),
    "extreme": PolicyCanvasLabSampleMinimumCounts(nodes: 32, edges: 41, groups: 6),
  ]

  @Test("Catalog is ordered simple to extreme and ids are unique")
  func catalogOrderAndUniqueIDs() {
    let ids = PolicyCanvasLabSamples.all.map(\.id)
    #expect(
      ids == [
        "minimal", "linear", "branching", "default-like", "real-default", "multi-group", "extreme",
      ]
    )
    #expect(Set(ids).count == ids.count)
    #expect(PolicyCanvasLabSamples.sample(id: PolicyCanvasLabSamples.defaultSelectionID) != nil)
  }

  @Test("Every sample meets its minimum node, edge, and group counts")
  func sampleCounts() {
    for sample in PolicyCanvasLabSamples.all {
      let document = sample.document
      let expected = Self.minimumCounts[sample.id]
      #expect(expected != nil, "missing expected counts for \(sample.id)")
      guard let expected else { continue }
      #expect(
        document.nodes.count >= expected.nodes,
        "\(sample.id) has \(document.nodes.count) nodes, want >= \(expected.nodes)"
      )
      #expect(
        document.edges.count >= expected.edges,
        "\(sample.id) has \(document.edges.count) edges, want >= \(expected.edges)"
      )
      #expect(
        document.groups.count >= expected.groups,
        "\(sample.id) has \(document.groups.count) groups, want >= \(expected.groups)"
      )
    }
  }

  @Test("Node ids are unique within every sample")
  func uniqueNodeIDs() {
    for sample in PolicyCanvasLabSamples.all {
      let ids = sample.document.nodes.map(\.id)
      #expect(Set(ids).count == ids.count, "\(sample.id) has duplicate node ids")
    }
  }

  @Test("Edge ids are unique within every sample")
  func uniqueEdgeIDs() {
    for sample in PolicyCanvasLabSamples.all {
      let ids = sample.document.edges.map(\.id)
      #expect(Set(ids).count == ids.count, "\(sample.id) has duplicate edge ids")
    }
  }

  @Test("Every edge endpoint resolves to a real node and a declared port")
  func edgeEndpointsResolve() {
    for sample in PolicyCanvasLabSamples.all {
      let document = sample.document
      let nodesByID = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, $0) })
      for edge in document.edges {
        guard let source = nodesByID[edge.fromNode] else {
          Issue.record("\(sample.id) edge \(edge.id) source node \(edge.fromNode) missing")
          continue
        }
        guard let target = nodesByID[edge.toNode] else {
          Issue.record("\(sample.id) edge \(edge.id) target node \(edge.toNode) missing")
          continue
        }
        #expect(
          source.outputPorts.contains(edge.fromPort),
          "\(sample.id) edge \(edge.id) source port \(edge.fromPort) not on \(source.id)"
        )
        #expect(
          target.inputPorts.contains(edge.toPort),
          "\(sample.id) edge \(edge.id) target port \(edge.toPort) not on \(target.id)"
        )
      }
    }
  }

  @Test("Every group member id resolves to a real node and every node has a layout seed")
  func groupMembersAndLayoutResolve() {
    for sample in PolicyCanvasLabSamples.all {
      let document = sample.document
      let nodeIDs = Set(document.nodes.map(\.id))
      for group in document.groups {
        for memberID in group.nodeIds {
          #expect(
            nodeIDs.contains(memberID),
            "\(sample.id) group \(group.id) lists missing node \(memberID)"
          )
        }
      }
      let layoutIDs = Set(document.layout.nodes.map(\.nodeId))
      #expect(
        layoutIDs == nodeIDs,
        "\(sample.id) layout seeds do not cover exactly the node set"
      )
    }
  }

  @Test("Reference algorithms produce coherent layouts for lab samples")
  func referenceAlgorithmsProduceCoherentLayoutsForLabSamples() throws {
    for sample in PolicyCanvasLabSamples.all {
      var nodes = sample.document.nodes.map {
        policyCanvasNode($0, layout: sample.document.layout)
      }
      var edges = sample.document.edges.compactMap { edge in
        policyCanvasEdge(edge, nodes: nodes)
      }
      var groups = sample.document.groups.enumerated().map { index, group in
        policyCanvasGroup(offset: index, element: group, nodes: nodes)
      }
      let result = try #require(
        policyCanvasAutomaticLayoutResult(
          nodes: nodes,
          groups: groups,
          edges: edges,
          mode: .explicitReflow(preserveManualAnchors: false),
          algorithmSelection: .referencePure
        ),
        "reference algorithms did not produce a layout for \(sample.id)"
      )
      _ = applyPolicyCanvasLayoutResult(
        result,
        nodes: &nodes,
        groups: &groups,
        centerInMinimumCanvas: true
      )
      edges = edges.map { edge in
        policyCanvasApplyingPreferredPortSides(edge, nodes: nodes)
      }

      #expect(!policyCanvasAnyNodeOverlap(nodes), "\(sample.id) has overlapping nodes")
      #expect(!policyCanvasAnyGroupOverlap(groups), "\(sample.id) has overlapping groups")
      #expect(
        !policyCanvasAnyNodeOutsideAssignedGroup(nodes: nodes, groups: groups),
        "\(sample.id) has nodes outside assigned groups"
      )
    }
  }

  @Test("Reference algorithms route lab samples around node bodies")
  func referenceAlgorithmsRouteLabSamplesAroundNodeBodies() async throws {
    for sample in PolicyCanvasLabSamples.all {
      let graph = try referenceLaidOutGraph(for: sample)
      let output = await PolicyCanvasRouteWorker().compute(
        input: PolicyCanvasRouteWorkerInput(
          nodes: graph.nodes,
          groups: graph.groups,
          edges: graph.edges,
          fontScale: 1,
          routingHints: graph.routingHints,
          algorithmSelection: .referencePure
        )
      )
      let nodeFrames = graph.nodes.map(policyCanvasNodeFrame)
      for edge in graph.edges {
        guard let route = output.routes[edge.id] else {
          Issue.record("\(sample.id) missing reference route for \(edge.id)")
          continue
        }
        let endpointFrames = Set([edge.source.nodeID, edge.target.nodeID])
        let obstacles = zip(graph.nodes, nodeFrames).compactMap { node, frame in
          endpointFrames.contains(node.id) ? nil : frame
        }
        #expect(
          !policyCanvasRouteIntersectsObstacles(route, obstacles: obstacles),
          "\(sample.id) route \(edge.id) intersects a non-endpoint node"
        )
      }
    }
  }

  private func referenceLaidOutGraph(
    for sample: PolicyCanvasLabSample
  ) throws -> PolicyCanvasReferenceGraph {
    var nodes = sample.document.nodes.map {
      policyCanvasNode($0, layout: sample.document.layout)
    }
    var edges = sample.document.edges.compactMap { edge in
      policyCanvasEdge(edge, nodes: nodes)
    }
    var groups = sample.document.groups.enumerated().map { index, group in
      policyCanvasGroup(offset: index, element: group, nodes: nodes)
    }
    let result = try #require(
      policyCanvasAutomaticLayoutResult(
        nodes: nodes,
        groups: groups,
        edges: edges,
        mode: .explicitReflow(preserveManualAnchors: false),
        algorithmSelection: .referencePure
      )
    )
    let routingHints = applyPolicyCanvasLayoutResult(
      result,
      nodes: &nodes,
      groups: &groups,
      centerInMinimumCanvas: true
    )
    edges = edges.map { edge in
      policyCanvasApplyingPreferredPortSides(edge, nodes: nodes)
    }
    return PolicyCanvasReferenceGraph(
      nodes: nodes,
      groups: groups,
      edges: edges,
      routingHints: routingHints
    )
  }
}

private struct PolicyCanvasLabSampleMinimumCounts {
  let nodes: Int
  let edges: Int
  let groups: Int
}

private struct PolicyCanvasReferenceGraph {
  let nodes: [PolicyCanvasNode]
  let groups: [PolicyCanvasGroup]
  let edges: [PolicyCanvasEdge]
  let routingHints: PolicyCanvasLayoutRoutingHints?
}
