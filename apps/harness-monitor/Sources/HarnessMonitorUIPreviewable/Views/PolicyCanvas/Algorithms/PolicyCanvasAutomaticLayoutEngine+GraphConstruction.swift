import CoreGraphics
import Foundation

// Layered-graph construction: longest-path rank assignment, edge
// acyclic-ization, and the augmented ordering-graph (with dummy chain nodes
// for long edges) consumed by the crossing-reduction sweeps.
func longestPathRanks(
  ids: [String],
  originalOrder: [String: Int],
  successors: [String: Set<String>]
) -> [String: Int] {
  var indegree = ids.reduce(into: [:]) { partial, id in
    partial[id] = 0
  }
  for targets in successors.values {
    for target in targets {
      indegree[target, default: 0] += 1
    }
  }

  // Min-heap keyed by originalOrder so the next pop is the lowest-order
  // indegree-zero node. The previous implementation re-sorted the queue
  // array on every dequeue (O(N log N) per pop, O(N^2 log N) total). Heap
  // push/pop is O(log N), giving O((N + E) log N).
  var queue = PolicyCanvasMinHeap<String>()
  for id in ids where (indegree[id] ?? 0) == 0 {
    queue.push(id, priority: CGFloat(originalOrder[id] ?? .max))
  }
  var ranks = ids.reduce(into: [:]) { partial, id in
    partial[id] = 0
  }
  var visited: Set<String> = []

  while let currentID = queue.pop() {
    visited.insert(currentID)
    let currentRank = ranks[currentID] ?? 0
    for nextID in successors[currentID] ?? [] {
      ranks[nextID] = max(ranks[nextID] ?? 0, currentRank + 1)
      indegree[nextID, default: 0] -= 1
      if indegree[nextID] == 0 {
        queue.push(nextID, priority: CGFloat(originalOrder[nextID] ?? .max))
      }
    }
  }

  for id in ids where !visited.contains(id) {
    ranks[id] = ranks[id] ?? 0
  }
  return ranks
}

func uniqueNodeIDs(_ nodeIDs: [String]) -> [String] {
  var seen: Set<String> = []
  return nodeIDs.filter { nodeID in
    seen.insert(nodeID).inserted
  }
}

func policyCanvasAcyclicEdges(
  ids: [String],
  originalOrder: [String: Int],
  edges: [PolicyCanvasLayoutEdge]
) -> [PolicyCanvasLayoutEdge] {
  let outgoing = edges.reduce(into: [:]) { partial, edge in
    partial[edge.sourceNodeID, default: []].append(edge)
  }
  let orderedIDs = ids.sorted { (originalOrder[$0] ?? .max) < (originalOrder[$1] ?? .max) }
  var visitState: [String: Int] = [:]
  var feedbackEdgeIDs: Set<String> = []

  func visit(_ nodeID: String) {
    visitState[nodeID] = 1
    let nextEdges = (outgoing[nodeID] ?? []).sorted {
      let leftTargetOrder = originalOrder[$0.targetNodeID] ?? .max
      let rightTargetOrder = originalOrder[$1.targetNodeID] ?? .max
      if leftTargetOrder != rightTargetOrder {
        return leftTargetOrder < rightTargetOrder
      }
      return $0.id < $1.id
    }
    for edge in nextEdges {
      let targetID = edge.targetNodeID
      switch visitState[targetID, default: 0] {
      case 0:
        visit(targetID)
      case 1:
        feedbackEdgeIDs.insert(edge.id)
      default:
        break
      }
    }
    visitState[nodeID] = 2
  }

  for nodeID in orderedIDs where visitState[nodeID, default: 0] == 0 {
    visit(nodeID)
  }

  return edges.map { edge in
    guard feedbackEdgeIDs.contains(edge.id) else {
      return edge
    }
    return PolicyCanvasLayoutEdge(
      id: edge.id,
      sourceNodeID: edge.targetNodeID,
      targetNodeID: edge.sourceNodeID,
      label: edge.label
    )
  }
}

func policyCanvasAugmentedLayeredOrderingGraph(
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
  var initialOrderByItemID = initialOrders
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
    let targetOrder = initialOrders[edge.targetNodeID] ?? sourceOrder
    let span = Double(targetRank - sourceRank)
    for intermediateRank in (sourceRank + 1)..<targetRank {
      let step = Double(intermediateRank - sourceRank)
      let dummyID = "__dummy__\(edge.id)#\(intermediateRank)"
      // Dummy IDs use the `__dummy__` prefix as a sentinel. Catch the rare
      // case where a real node carries an ID that collides with the dummy
      // pattern; silently overwriting the real entry would scramble the
      // rank assignment for the downstream Sugiyama passes.
      assert(
        itemsByID[dummyID] == nil,
        "PolicyCanvas dummy ID collides with an existing item: \(dummyID)"
      )
      itemsByID[dummyID] = PolicyCanvasLayeredOrderingItem(
        id: dummyID,
        realNodeID: nil,
        rank: intermediateRank
      )
      initialOrderByItemID[dummyID] =
        sourceOrder
        + ((targetOrder - sourceOrder) * (step / span))
        + (Double(edgeIndex) / 10_000)
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
      let leftOrder = initialOrderByItemID[leftID] ?? 0
      let rightOrder = initialOrderByItemID[rightID] ?? 0
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
