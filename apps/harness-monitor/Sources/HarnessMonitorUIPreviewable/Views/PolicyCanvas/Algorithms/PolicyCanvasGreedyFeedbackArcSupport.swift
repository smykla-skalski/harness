import Foundation

func policyCanvasGreedyFeedbackArcOrder(
  nodeIDs: [String],
  originalOrder: [String: Int],
  edges: [PolicyCanvasLayoutEdge]
) -> [String: Int] {
  var remaining = Set(nodeIDs)
  var outgoing: [String: Set<String>] = [:]
  var incoming: [String: Set<String>] = [:]
  for edge in edges where edge.sourceNodeID != edge.targetNodeID {
    guard remaining.contains(edge.sourceNodeID), remaining.contains(edge.targetNodeID) else {
      continue
    }
    outgoing[edge.sourceNodeID, default: []].insert(edge.targetNodeID)
    incoming[edge.targetNodeID, default: []].insert(edge.sourceNodeID)
  }

  var left: [String] = []
  var right: [String] = []
  while !remaining.isEmpty {
    while let sink = policyCanvasGreedySink(
      in: remaining,
      outgoing: outgoing,
      originalOrder: originalOrder
    ) {
      policyCanvasRemoveGreedyVertex(
        sink,
        remaining: &remaining,
        outgoing: &outgoing,
        incoming: &incoming
      )
      right.insert(sink, at: 0)
    }
    while let source = policyCanvasGreedySource(
      in: remaining,
      incoming: incoming,
      originalOrder: originalOrder
    ) {
      policyCanvasRemoveGreedyVertex(
        source,
        remaining: &remaining,
        outgoing: &outgoing,
        incoming: &incoming
      )
      left.append(source)
    }
    if let vertex = policyCanvasGreedyMaximumDegreeDelta(
      in: remaining,
      outgoing: outgoing,
      incoming: incoming,
      originalOrder: originalOrder
    ) {
      policyCanvasRemoveGreedyVertex(
        vertex,
        remaining: &remaining,
        outgoing: &outgoing,
        incoming: &incoming
      )
      left.append(vertex)
    }
  }

  return Dictionary(
    uniqueKeysWithValues: (left + right).enumerated().map { index, nodeID in
      (nodeID, index)
    }
  )
}

func policyCanvasEdgesOrientedByOrder(
  _ edges: [PolicyCanvasLayoutEdge],
  order: [String: Int]
) -> [PolicyCanvasLayoutEdge] {
  edges.map { edge in
    let sourceOrder = order[edge.sourceNodeID] ?? .max
    let targetOrder = order[edge.targetNodeID] ?? .max
    guard sourceOrder <= targetOrder else {
      return PolicyCanvasLayoutEdge(
        id: edge.id,
        sourceNodeID: edge.targetNodeID,
        targetNodeID: edge.sourceNodeID,
        label: edge.label
      )
    }
    return edge
  }
}

private func policyCanvasGreedySink(
  in remaining: Set<String>,
  outgoing: [String: Set<String>],
  originalOrder: [String: Int]
) -> String? {
  remaining
    .filter { nodeID in
      (outgoing[nodeID] ?? []).isDisjoint(with: remaining)
    }
    .min { left, right in
      policyCanvasOriginalOrderLessThan(left, right, originalOrder: originalOrder)
    }
}

private func policyCanvasGreedySource(
  in remaining: Set<String>,
  incoming: [String: Set<String>],
  originalOrder: [String: Int]
) -> String? {
  remaining
    .filter { nodeID in
      (incoming[nodeID] ?? []).isDisjoint(with: remaining)
    }
    .min { left, right in
      policyCanvasOriginalOrderLessThan(left, right, originalOrder: originalOrder)
    }
}

private func policyCanvasGreedyMaximumDegreeDelta(
  in remaining: Set<String>,
  outgoing: [String: Set<String>],
  incoming: [String: Set<String>],
  originalOrder: [String: Int]
) -> String? {
  remaining.max { left, right in
    let leftDelta = policyCanvasGreedyDegreeDelta(
      left,
      remaining: remaining,
      outgoing: outgoing,
      incoming: incoming
    )
    let rightDelta = policyCanvasGreedyDegreeDelta(
      right,
      remaining: remaining,
      outgoing: outgoing,
      incoming: incoming
    )
    if leftDelta != rightDelta {
      return leftDelta < rightDelta
    }
    return !policyCanvasOriginalOrderLessThan(left, right, originalOrder: originalOrder)
  }
}

private func policyCanvasGreedyDegreeDelta(
  _ nodeID: String,
  remaining: Set<String>,
  outgoing: [String: Set<String>],
  incoming: [String: Set<String>]
) -> Int {
  (outgoing[nodeID] ?? []).intersection(remaining).count
    - (incoming[nodeID] ?? []).intersection(remaining).count
}

private func policyCanvasRemoveGreedyVertex(
  _ nodeID: String,
  remaining: inout Set<String>,
  outgoing: inout [String: Set<String>],
  incoming: inout [String: Set<String>]
) {
  remaining.remove(nodeID)
  for target in outgoing[nodeID] ?? [] {
    incoming[target]?.remove(nodeID)
  }
  for source in incoming[nodeID] ?? [] {
    outgoing[source]?.remove(nodeID)
  }
  outgoing[nodeID] = []
  incoming[nodeID] = []
}

private func policyCanvasOriginalOrderLessThan(
  _ left: String,
  _ right: String,
  originalOrder: [String: Int]
) -> Bool {
  let leftOrder = originalOrder[left] ?? .max
  let rightOrder = originalOrder[right] ?? .max
  if leftOrder != rightOrder {
    return leftOrder < rightOrder
  }
  return left < right
}
