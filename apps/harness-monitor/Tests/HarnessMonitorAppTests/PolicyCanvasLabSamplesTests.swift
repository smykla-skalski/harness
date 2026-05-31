import HarnessMonitorKit
import Testing

@testable import HarnessMonitor

/// Producer guard for the Policy Canvas Lab sample picker: every named sample
/// must be a valid graph the picker can render. Builds each sample and asserts
/// non-empty node/edge/group counts, unique node ids, and that every edge
/// endpoint resolves to a real node and a port that node actually declares.
@Suite("Policy canvas lab samples")
struct PolicyCanvasLabSamplesTests {
  /// Minimum node / edge / group counts expected per sample id. Guards against
  /// a sample silently collapsing to a trivial graph.
  private static let minimumCounts: [String: (nodes: Int, edges: Int, groups: Int)] = [
    "minimal": (2, 1, 1),
    "linear": (6, 5, 3),
    "branching": (9, 10, 3),
    "default-like": (16, 21, 3),
    "multi-group": (14, 21, 4),
    "extreme": (32, 41, 6),
  ]

  @Test("Catalog is ordered simple to extreme and ids are unique")
  func catalogOrderAndUniqueIDs() {
    let ids = PolicyCanvasLabSamples.all.map(\.id)
    #expect(ids == ["minimal", "linear", "branching", "default-like", "multi-group", "extreme"])
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
}
