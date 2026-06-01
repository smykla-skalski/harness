import CoreGraphics
import Foundation

func policyCanvasLayerOrderHints(
  layers: [[String]],
  graph: PolicyCanvasLayeredOrderingGraph
) -> [String: Double] {
  var orderHints: [String: Double] = [:]
  for layer in layers {
    let realNodeIDs = layer.compactMap { graph.itemsByID[$0]?.realNodeID }
    for (index, nodeID) in realNodeIDs.enumerated() {
      orderHints[nodeID] = Double(index)
    }
  }
  return orderHints
}

func policyCanvasLayoutGroupIDsByNodeID(
  graph: PolicyCanvasLayoutGraph,
  normalizedGroups: [PolicyCanvasNormalizedLayoutGroup]
) -> [String: String] {
  var result: [String: String] = [:]
  for group in normalizedGroups {
    for nodeID in uniqueNodeIDs(group.nodeIDs) {
      result[nodeID] = group.layoutID
    }
  }
  for node in graph.nodes {
    if let groupID = node.groupID {
      result[node.id] = groupID
    }
    if result[node.id] == nil {
      result[node.id] = "__ungrouped__\(node.id)"
    }
  }
  return result
}

func policyCanvasScopeRanks(
  nodeRanks: [String: Int],
  layoutGroupIDByNodeID: [String: String]
) -> [String: Int] {
  layoutGroupIDByNodeID.reduce(into: [:]) { partial, entry in
    let rank = nodeRanks[entry.key] ?? 0
    partial[entry.value] = min(partial[entry.value] ?? rank, rank)
  }
}

func policyCanvasAutoPlacedNodeIDs(
  graph: PolicyCanvasLayoutGraph,
  mode: PolicyCanvasAutomaticLayoutMode
) -> Set<String> {
  Set(
    graph.nodes.compactMap { node in
      if mode.preservesManualAnchors, node.anchor != nil {
        return nil
      }
      return node.id
    }
  )
}

func policyCanvasPureUnitLayeredOrderingGraph(
  nodeIDs: [String],
  ranks: [String: Int],
  edges: [PolicyCanvasLayoutEdge],
  initialOrders: [String: Double]
) -> PolicyCanvasLayeredOrderingGraph {
  var itemsByID = Dictionary(
    uniqueKeysWithValues: nodeIDs.map { nodeID in
      (
        nodeID,
        PolicyCanvasLayeredOrderingItem(
          id: nodeID,
          realNodeID: nodeID,
          rank: ranks[nodeID] ?? 0
        )
      )
    })
  var outgoing: [String: [String]] = [:]
  var incoming: [String: [String]] = [:]
  var orderByItemID = initialOrders
  let maxRank = max(0, itemsByID.values.map(\.rank).max() ?? 0)

  func connect(_ sourceID: String, _ targetID: String) {
    outgoing[sourceID, default: []].append(targetID)
    incoming[targetID, default: []].append(sourceID)
  }

  for (edgeIndex, edge) in edges.enumerated() {
    let sourceRank = ranks[edge.sourceNodeID] ?? 0
    let targetRank = ranks[edge.targetNodeID] ?? 0
    guard targetRank > sourceRank else {
      continue
    }
    if targetRank == sourceRank + 1 {
      connect(edge.sourceNodeID, edge.targetNodeID)
      continue
    }
    var previousID = edge.sourceNodeID
    let sourceOrder = initialOrders[edge.sourceNodeID] ?? 0
    for intermediateRank in (sourceRank + 1)..<targetRank {
      let dummyID = "__dummy__\(edge.id)#\(intermediateRank)"
      assert(
        itemsByID[dummyID] == nil,
        "PolicyCanvas dummy ID collides with an existing item: \(dummyID)"
      )
      itemsByID[dummyID] = PolicyCanvasLayeredOrderingItem(
        id: dummyID,
        realNodeID: nil,
        rank: intermediateRank
      )
      orderByItemID[dummyID] = sourceOrder + (Double(edgeIndex) / 10_000)
      connect(previousID, dummyID)
      previousID = dummyID
    }
    connect(previousID, edge.targetNodeID)
  }

  var layers = Array(repeating: [String](), count: maxRank + 1)
  for item in itemsByID.values {
    layers[item.rank].append(item.id)
  }
  for rank in layers.indices {
    layers[rank].sort { leftID, rightID in
      let leftOrder = orderByItemID[leftID] ?? 0
      let rightOrder = orderByItemID[rightID] ?? 0
      if leftOrder != rightOrder {
        return leftOrder < rightOrder
      }
      let leftItem = itemsByID[leftID]
      let rightItem = itemsByID[rightID]
      if leftItem?.isDummy != rightItem?.isDummy {
        return rightItem?.isDummy ?? false
      }
      return leftID < rightID
    }
  }

  return PolicyCanvasLayeredOrderingGraph(
    itemsByID: itemsByID,
    layers: layers,
    incoming: incoming.mapValues { $0.sorted() },
    outgoing: outgoing.mapValues { $0.sorted() }
  )
}

func policyCanvasPureBarycenterLayerOrders(
  graph: PolicyCanvasLayeredOrderingGraph,
  maxPasses: Int
) -> [[String]] {
  var layers = graph.layers
  let passLimit = max(1, maxPasses)
  for _ in 0..<passLimit {
    var changed = false
    changed =
      policyCanvasPureBarycenterSweep(
        layers: &layers,
        graph: graph,
        forward: true
      )
      || changed
    changed =
      policyCanvasPureBarycenterSweep(
        layers: &layers,
        graph: graph,
        forward: false
      )
      || changed
    if !changed {
      break
    }
  }
  return layers
}

private func policyCanvasPureBarycenterSweep(
  layers: inout [[String]],
  graph: PolicyCanvasLayeredOrderingGraph,
  forward: Bool
) -> Bool {
  guard layers.count > 1 else {
    return false
  }
  let layerIndexes =
    forward
    ? Array(1..<layers.count)
    : Array(stride(from: layers.count - 2, through: 0, by: -1))
  var changed = false

  for movingRank in layerIndexes {
    let fixedRank = forward ? movingRank - 1 : movingRank + 1
    let currentOrder = Dictionary(
      uniqueKeysWithValues: layers[movingRank].enumerated().map { ($1, $0) }
    )
    let fixedOrder = Dictionary(
      uniqueKeysWithValues: layers[fixedRank].enumerated().map { ($1, $0) }
    )
    let reordered = layers[movingRank].sorted { leftID, rightID in
      let leftScore = policyCanvasPureBarycenterScore(
        itemID: leftID,
        graph: graph,
        fixedOrder: fixedOrder,
        forward: forward,
        fallbackOrder: currentOrder[leftID] ?? 0
      )
      let rightScore = policyCanvasPureBarycenterScore(
        itemID: rightID,
        graph: graph,
        fixedOrder: fixedOrder,
        forward: forward,
        fallbackOrder: currentOrder[rightID] ?? 0
      )
      if leftScore != rightScore {
        return leftScore < rightScore
      }
      return (currentOrder[leftID] ?? 0) < (currentOrder[rightID] ?? 0)
    }
    if reordered != layers[movingRank] {
      changed = true
      layers[movingRank] = reordered
    }
  }

  return changed
}

private func policyCanvasPureBarycenterScore(
  itemID: String,
  graph: PolicyCanvasLayeredOrderingGraph,
  fixedOrder: [String: Int],
  forward: Bool,
  fallbackOrder: Int
) -> Double {
  let neighbors = forward ? (graph.incoming[itemID] ?? []) : (graph.outgoing[itemID] ?? [])
  let neighborOrders = neighbors.compactMap { neighborID in
    fixedOrder[neighborID].map(Double.init)
  }
  guard !neighborOrders.isEmpty else {
    return Double(fallbackOrder)
  }
  return neighborOrders.reduce(0, +) / Double(neighborOrders.count)
}

func policyCanvasRebuiltGroupFramesByLayoutID(
  normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
  layoutGroupIDByNodeID: [String: String],
  nodePositions: [String: CGPoint]
) -> [String: CGRect] {
  var frames: [String: CGRect] = [:]
  for group in normalizedGroups {
    let bounds = group.nodeIDs
      .filter { layoutGroupIDByNodeID[$0] == group.layoutID }
      .reduce(CGRect.null) { partial, nodeID in
        guard let position = nodePositions[nodeID] else {
          return partial
        }
        return partial.union(CGRect(origin: position, size: PolicyCanvasLayout.nodeSize))
      }
    guard !bounds.isNull else {
      continue
    }
    if group.actualGroupID == nil {
      frames[group.layoutID] = bounds.integral
    } else {
      frames[group.layoutID] = policyCanvasGroupFrame(containing: bounds)
    }
  }
  return frames
}
