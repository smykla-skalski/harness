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
