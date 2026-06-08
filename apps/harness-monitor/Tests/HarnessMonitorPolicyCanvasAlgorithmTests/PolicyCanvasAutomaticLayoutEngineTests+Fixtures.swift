import CoreGraphics
import Foundation

@testable import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasAutomaticLayoutEngineTests {
  func crossingReductionGraph() -> PolicyCanvasLayoutGraph {
    PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "a",
          groupID: "main",
          originalIndex: 0,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "b",
          groupID: "main",
          originalIndex: 1,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "c",
          groupID: "main",
          originalIndex: 2,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "d",
          groupID: "main",
          originalIndex: 3,
          currentPosition: .zero,
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "a-d", sourceNodeID: "a", targetNodeID: "d"),
        PolicyCanvasLayoutEdge(id: "b-c", sourceNodeID: "b", targetNodeID: "c"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(
          id: "main",
          originalIndex: 0,
          memberNodeIDs: ["a", "b", "c", "d"]
        )
      ]
    )
  }

  func cycleGraph() -> PolicyCanvasLayoutGraph {
    PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "a", groupID: "cycle", originalIndex: 0, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(
          id: "b", groupID: "cycle", originalIndex: 1, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(
          id: "c", groupID: "cycle", originalIndex: 2, currentPosition: .zero, anchor: nil),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "a-b", sourceNodeID: "a", targetNodeID: "b"),
        PolicyCanvasLayoutEdge(id: "b-c", sourceNodeID: "b", targetNodeID: "c"),
        PolicyCanvasLayoutEdge(id: "c-a", sourceNodeID: "c", targetNodeID: "a"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(id: "cycle", originalIndex: 0, memberNodeIDs: ["a", "b", "c"])
      ]
    )
  }

  func fanoutGraph() -> PolicyCanvasLayoutGraph {
    PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "source", groupID: "entry", originalIndex: 0, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(
          id: "sink-a", groupID: "terminal", originalIndex: 1, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(
          id: "sink-b", groupID: "terminal", originalIndex: 2, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(
          id: "sink-c", groupID: "terminal", originalIndex: 3, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(
          id: "sink-d", groupID: "terminal", originalIndex: 4, currentPosition: .zero, anchor: nil),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "source-a", sourceNodeID: "source", targetNodeID: "sink-a"),
        PolicyCanvasLayoutEdge(id: "source-b", sourceNodeID: "source", targetNodeID: "sink-b"),
        PolicyCanvasLayoutEdge(id: "source-c", sourceNodeID: "source", targetNodeID: "sink-c"),
        PolicyCanvasLayoutEdge(id: "source-d", sourceNodeID: "source", targetNodeID: "sink-d"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(id: "entry", originalIndex: 0, memberNodeIDs: ["source"]),
        PolicyCanvasLayoutGroup(
          id: "terminal",
          originalIndex: 1,
          memberNodeIDs: ["sink-a", "sink-b", "sink-c", "sink-d"]
        ),
      ]
    )
  }

  func sameRankGroupOrderingGraph() -> PolicyCanvasLayoutGraph {
    PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "source-a",
          groupID: "source-a-group",
          originalIndex: 0,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "source-b",
          groupID: "source-b-group",
          originalIndex: 1,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "target-b",
          groupID: "target-b-group",
          originalIndex: 2,
          currentPosition: .zero,
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "target-a",
          groupID: "target-a-group",
          originalIndex: 3,
          currentPosition: .zero,
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "a-a", sourceNodeID: "source-a", targetNodeID: "target-a"),
        PolicyCanvasLayoutEdge(id: "b-b", sourceNodeID: "source-b", targetNodeID: "target-b"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(
          id: "source-a-group",
          originalIndex: 0,
          memberNodeIDs: ["source-a"]
        ),
        PolicyCanvasLayoutGroup(
          id: "source-b-group",
          originalIndex: 1,
          memberNodeIDs: ["source-b"]
        ),
        PolicyCanvasLayoutGroup(
          id: "target-b-group",
          originalIndex: 2,
          memberNodeIDs: ["target-b"]
        ),
        PolicyCanvasLayoutGroup(
          id: "target-a-group",
          originalIndex: 3,
          memberNodeIDs: ["target-a"]
        ),
      ]
    )
  }

  func sparsePressureGraph() -> PolicyCanvasLayoutGraph {
    PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "source", groupID: "entry", originalIndex: 0, currentPosition: .zero, anchor: nil),
        PolicyCanvasLayoutNode(
          id: "target", groupID: "terminal", originalIndex: 1, currentPosition: .zero, anchor: nil),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "source-target", sourceNodeID: "source", targetNodeID: "target")
      ],
      groups: [
        PolicyCanvasLayoutGroup(id: "entry", originalIndex: 0, memberNodeIDs: ["source"]),
        PolicyCanvasLayoutGroup(id: "terminal", originalIndex: 1, memberNodeIDs: ["target"]),
      ]
    )
  }

  func densePressureGraph(sinkCount: Int) -> PolicyCanvasLayoutGraph {
    let sinks = (0..<sinkCount).map { index in
      PolicyCanvasLayoutNode(
        id: "sink-\(index)",
        groupID: "terminal",
        originalIndex: index + 1,
        currentPosition: .zero,
        anchor: nil
      )
    }
    return PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "source", groupID: "entry", originalIndex: 0, currentPosition: .zero, anchor: nil)
      ] + sinks,
      edges: sinks.map { sink in
        PolicyCanvasLayoutEdge(
          id: "source-\(sink.id)",
          sourceNodeID: "source",
          targetNodeID: sink.id
        )
      },
      groups: [
        PolicyCanvasLayoutGroup(id: "entry", originalIndex: 0, memberNodeIDs: ["source"]),
        PolicyCanvasLayoutGroup(
          id: "terminal",
          originalIndex: 1,
          memberNodeIDs: sinks.map(\.id)
        ),
      ]
    )
  }

  func harnessRankAssignment(for graph: PolicyCanvasLayoutGraph) -> PolicyCanvasRankAssignmentOutput {
    PolicyCanvasHarnessGroupAwareLongestPathLayering().assignRanks(
      input: PolicyCanvasRankAssignmentInput(
        graph: graph,
        nodeIDs: graph.nodes.map(\.id),
        originalOrder: Dictionary(
          uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.originalIndex) }),
        edges: graph.edges,
        mode: .initialLoad
      )
    )
  }

  func multiGroupCollectorGraph() -> PolicyCanvasLayoutGraph {
    PolicyCanvasLayoutGraph(
      nodes: [
        PolicyCanvasLayoutNode(
          id: "mg-pre",
          groupID: "intake",
          originalIndex: 0,
          currentPosition: CGPoint(x: 120, y: 260),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "intake",
          groupID: "intake",
          originalIndex: 1,
          currentPosition: CGPoint(x: 360, y: 260),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "rv-switch",
          groupID: "review",
          originalIndex: 2,
          currentPosition: CGPoint(x: 760, y: 140),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "rv-evidence",
          groupID: "review",
          originalIndex: 3,
          currentPosition: CGPoint(x: 1000, y: 140),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "rv-ifelse",
          groupID: "review",
          originalIndex: 4,
          currentPosition: CGPoint(x: 760, y: 360),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "rv-consensus",
          groupID: "review",
          originalIndex: 5,
          currentPosition: CGPoint(x: 1000, y: 360),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "dp-risk",
          groupID: "deploy",
          originalIndex: 6,
          currentPosition: CGPoint(x: 760, y: 620),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "dp-wait",
          groupID: "deploy",
          originalIndex: 7,
          currentPosition: CGPoint(x: 1000, y: 620),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "dp-evidence",
          groupID: "deploy",
          originalIndex: 8,
          currentPosition: CGPoint(x: 760, y: 840),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "dp-action",
          groupID: "deploy",
          originalIndex: 9,
          currentPosition: CGPoint(x: 1000, y: 840),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "out-human",
          groupID: "outcomes",
          originalIndex: 10,
          currentPosition: CGPoint(x: 1420, y: 220),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "out-allow",
          groupID: "outcomes",
          originalIndex: 11,
          currentPosition: CGPoint(x: 1680, y: 220),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "out-deny",
          groupID: "outcomes",
          originalIndex: 12,
          currentPosition: CGPoint(x: 1420, y: 620),
          anchor: nil
        ),
        PolicyCanvasLayoutNode(
          id: "out-finish",
          groupID: "outcomes",
          originalIndex: 13,
          currentPosition: CGPoint(x: 1680, y: 620),
          anchor: nil
        ),
      ],
      edges: [
        PolicyCanvasLayoutEdge(id: "e:pre-intake", sourceNodeID: "mg-pre", targetNodeID: "intake"),
        PolicyCanvasLayoutEdge(id: "e:pre-deny", sourceNodeID: "mg-pre", targetNodeID: "out-deny"),
        PolicyCanvasLayoutEdge(id: "e:in-rv", sourceNodeID: "intake", targetNodeID: "rv-switch"),
        PolicyCanvasLayoutEdge(id: "e:in-dp", sourceNodeID: "intake", targetNodeID: "dp-risk"),
        PolicyCanvasLayoutEdge(id: "e:rvs-pass", sourceNodeID: "rv-switch", targetNodeID: "rv-evidence"),
        PolicyCanvasLayoutEdge(id: "e:rvs-esc", sourceNodeID: "rv-switch", targetNodeID: "out-human"),
        PolicyCanvasLayoutEdge(id: "e:rvs-def", sourceNodeID: "rv-switch", targetNodeID: "out-deny"),
        PolicyCanvasLayoutEdge(id: "e:rv-pass", sourceNodeID: "rv-evidence", targetNodeID: "rv-ifelse"),
        PolicyCanvasLayoutEdge(id: "e:rv-fail", sourceNodeID: "rv-evidence", targetNodeID: "out-deny"),
        PolicyCanvasLayoutEdge(id: "e:rv-missing", sourceNodeID: "rv-evidence", targetNodeID: "out-human"),
        PolicyCanvasLayoutEdge(id: "e:rv-then", sourceNodeID: "rv-ifelse", targetNodeID: "rv-consensus"),
        PolicyCanvasLayoutEdge(id: "e:rv-else", sourceNodeID: "rv-ifelse", targetNodeID: "out-human"),
        PolicyCanvasLayoutEdge(id: "e:rv-allow", sourceNodeID: "rv-consensus", targetNodeID: "out-allow"),
        PolicyCanvasLayoutEdge(id: "e:dp-low", sourceNodeID: "dp-risk", targetNodeID: "dp-wait"),
        PolicyCanvasLayoutEdge(id: "e:dp-high", sourceNodeID: "dp-risk", targetNodeID: "out-deny"),
        PolicyCanvasLayoutEdge(id: "e:dp-missing", sourceNodeID: "dp-risk", targetNodeID: "out-human"),
        PolicyCanvasLayoutEdge(id: "e:dp-wait-ev", sourceNodeID: "dp-wait", targetNodeID: "dp-evidence"),
        PolicyCanvasLayoutEdge(id: "e:dp-pass", sourceNodeID: "dp-evidence", targetNodeID: "dp-action"),
        PolicyCanvasLayoutEdge(id: "e:dp-fail", sourceNodeID: "dp-evidence", targetNodeID: "out-deny"),
        PolicyCanvasLayoutEdge(id: "e:dp-ev-missing", sourceNodeID: "dp-evidence", targetNodeID: "out-human"),
        PolicyCanvasLayoutEdge(id: "e:dp-finish", sourceNodeID: "dp-action", targetNodeID: "out-finish"),
      ],
      groups: [
        PolicyCanvasLayoutGroup(id: "intake", originalIndex: 0, memberNodeIDs: ["mg-pre", "intake"]),
        PolicyCanvasLayoutGroup(
          id: "review",
          originalIndex: 1,
          memberNodeIDs: ["rv-switch", "rv-evidence", "rv-ifelse", "rv-consensus"]
        ),
        PolicyCanvasLayoutGroup(
          id: "deploy",
          originalIndex: 2,
          memberNodeIDs: ["dp-risk", "dp-wait", "dp-evidence", "dp-action"]
        ),
        PolicyCanvasLayoutGroup(
          id: "outcomes",
          originalIndex: 3,
          memberNodeIDs: ["out-human", "out-allow", "out-deny", "out-finish"]
        ),
      ]
    )
  }

  func denseOrderingGraph(
    layerCount: Int,
    layerWidth: Int
  ) -> PolicyCanvasLayeredOrderingGraph {
    let layers = (0..<layerCount).map { rank in
      (0..<layerWidth).map { index in
        "layer-\(rank)-item-\(index)"
      }
    }
    let itemsByID = Dictionary(
      uniqueKeysWithValues: layers.enumerated().flatMap { rank, layer in
        layer.map { itemID in
          (
            itemID,
            PolicyCanvasLayeredOrderingItem(
              id: itemID,
              realNodeID: itemID,
              rank: rank
            )
          )
        }
      }
    )
    var incoming: [String: [String]] = [:]
    var outgoing: [String: [String]] = [:]

    for rank in 0..<(layerCount - 1) {
      for sourceID in layers[rank] {
        for targetID in layers[rank + 1] {
          outgoing[sourceID, default: []].append(targetID)
          incoming[targetID, default: []].append(sourceID)
        }
      }
    }

    return PolicyCanvasLayeredOrderingGraph(
      itemsByID: itemsByID,
      layers: layers,
      incoming: incoming,
      outgoing: outgoing
    )
  }

  func bilayerCrossingCount(
    _ layers: [[String]],
    graph: PolicyCanvasLayeredOrderingGraph
  ) -> Int {
    guard layers.count >= 2 else {
      return 0
    }
    let upperOrder = Dictionary(uniqueKeysWithValues: layers[0].enumerated().map { ($1, $0) })
    let lowerOrder = Dictionary(uniqueKeysWithValues: layers[1].enumerated().map { ($1, $0) })
    let edgePairs = layers[0].flatMap { sourceID -> [(Int, Int)] in
      (graph.outgoing[sourceID] ?? []).compactMap { targetID in
        guard let upperIndex = upperOrder[sourceID], let lowerIndex = lowerOrder[targetID] else {
          return nil
        }
        return (upperIndex, lowerIndex)
      }
    }
    var crossings = 0
    for leftIndex in edgePairs.indices {
      for rightIndex in edgePairs.index(after: leftIndex)..<edgePairs.endIndex {
        let left = edgePairs[leftIndex]
        let right = edgePairs[rightIndex]
        if (left.0 < right.0 && left.1 > right.1) || (left.0 > right.0 && left.1 < right.1) {
          crossings += 1
        }
      }
    }
    return crossings
  }
}
