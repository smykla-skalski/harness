import Foundation
import SwiftUI

func policyCanvasMeasureLayoutMetrics(
  graph: PolicyCanvasLayoutGraph,
  nodePositions: [String: CGPoint],
  groupRanks: [String: Int],
  layoutGroupIDByNodeID: [String: String]
) -> PolicyCanvasLayoutMetrics {
  let crossGroupViolations = policyCanvasCrossGroupOrderViolations(
    graph: graph,
    groupRanks: groupRanks,
    layoutGroupIDByNodeID: layoutGroupIDByNodeID
  )
  let nodeCenters: [String: CGPoint] = Dictionary(
    uniqueKeysWithValues: graph.nodes.compactMap { node in
      guard let position = nodePositions[node.id] else {
        return nil
      }
      let frame = CGRect(origin: position, size: PolicyCanvasLayout.nodeSize)
      return (node.id, CGPoint(x: frame.midX, y: frame.midY))
    }
  )
  let edgeCrossings = policyCanvasStraightLineEdgeCrossingCount(
    edges: graph.edges,
    nodeCenters: nodeCenters
  )
  let flowDirectionViolations = graph.edges.reduce(into: 0) { count, edge in
    guard
      let sourceCenter = nodeCenters[edge.sourceNodeID],
      let targetCenter = nodeCenters[edge.targetNodeID]
    else {
      return
    }
    if targetCenter.x + 1 < sourceCenter.x {
      count += 1
    }
  }
  let edgeLengths = graph.edges.compactMap { edge -> Double? in
    guard
      let sourceCenter = nodeCenters[edge.sourceNodeID],
      let targetCenter = nodeCenters[edge.targetNodeID]
    else {
      return nil
    }
    return hypot(
      Double(targetCenter.x - sourceCenter.x),
      Double(targetCenter.y - sourceCenter.y)
    )
  }
  let averageEdgeLength =
    edgeLengths.isEmpty
    ? 0
    : edgeLengths.reduce(0, +) / Double(edgeLengths.count)
  let edgeLengthVariance: Double = {
    guard !edgeLengths.isEmpty else {
      return 0
    }
    return edgeLengths.reduce(into: 0) { partial, length in
      let delta = length - averageEdgeLength
      partial += delta * delta
    } / Double(edgeLengths.count)
  }()
  let normalizedLengthVariance =
    averageEdgeLength > 0
    ? edgeLengthVariance / max(1.0, averageEdgeLength * averageEdgeLength)
    : 0
  let readabilityScore = max(
    0,
    1_000
      - Double(edgeCrossings * 220)
      - Double(flowDirectionViolations * 80)
      - Double(crossGroupViolations * 120)
      - (normalizedLengthVariance * 100)
  )
  return PolicyCanvasLayoutMetrics(
    macroLayerCount: Set(groupRanks.values).count,
    crossGroupOrderViolations: crossGroupViolations,
    anchoredNodeCount: graph.nodes.reduce(into: 0) { count, node in
      if node.anchor != nil {
        count += 1
      }
    },
    edgeCrossingCount: edgeCrossings,
    flowDirectionViolationCount: flowDirectionViolations,
    averageEdgeLength: averageEdgeLength,
    edgeLengthVariance: edgeLengthVariance,
    readabilityScore: readabilityScore
  )
}

private func policyCanvasCrossGroupOrderViolations(
  graph: PolicyCanvasLayoutGraph,
  groupRanks: [String: Int],
  layoutGroupIDByNodeID: [String: String]
) -> Int {
  graph.edges.reduce(into: 0) { partial, edge in
    guard
      let sourceGroupID = layoutGroupIDByNodeID[edge.sourceNodeID],
      let targetGroupID = layoutGroupIDByNodeID[edge.targetNodeID],
      sourceGroupID != targetGroupID,
      let sourceRank = groupRanks[sourceGroupID],
      let targetRank = groupRanks[targetGroupID],
      sourceRank > targetRank
    else {
      return
    }
    partial += 1
  }
}

private func policyCanvasStraightLineEdgeCrossingCount(
  edges: [PolicyCanvasLayoutEdge],
  nodeCenters: [String: CGPoint]
) -> Int {
  var crossings = 0
  for leftIndex in edges.indices {
    for rightIndex in edges.index(after: leftIndex)..<edges.endIndex {
      let left = edges[leftIndex]
      let right = edges[rightIndex]
      if left.sourceNodeID == right.sourceNodeID
        || left.sourceNodeID == right.targetNodeID
        || left.targetNodeID == right.sourceNodeID
        || left.targetNodeID == right.targetNodeID
      {
        continue
      }
      guard
        let leftSource = nodeCenters[left.sourceNodeID],
        let leftTarget = nodeCenters[left.targetNodeID],
        let rightSource = nodeCenters[right.sourceNodeID],
        let rightTarget = nodeCenters[right.targetNodeID]
      else {
        continue
      }
      if policyCanvasSegmentsIntersect(
        leftSource,
        leftTarget,
        rightSource,
        rightTarget
      ) {
        crossings += 1
      }
    }
  }
  return crossings
}

private func policyCanvasSegmentsIntersect(
  _ a1: CGPoint,
  _ a2: CGPoint,
  _ b1: CGPoint,
  _ b2: CGPoint
) -> Bool {
  let epsilon: CGFloat = 0.001
  let o1 = policyCanvasOrientation(a1, a2, b1)
  let o2 = policyCanvasOrientation(a1, a2, b2)
  let o3 = policyCanvasOrientation(b1, b2, a1)
  let o4 = policyCanvasOrientation(b1, b2, a2)

  if o1 == 0, policyCanvasPoint(b1, liesOn: a1, to: a2, epsilon: epsilon) {
    return true
  }
  if o2 == 0, policyCanvasPoint(b2, liesOn: a1, to: a2, epsilon: epsilon) {
    return true
  }
  if o3 == 0, policyCanvasPoint(a1, liesOn: b1, to: b2, epsilon: epsilon) {
    return true
  }
  if o4 == 0, policyCanvasPoint(a2, liesOn: b1, to: b2, epsilon: epsilon) {
    return true
  }
  return o1 != o2 && o3 != o4
}

private func policyCanvasOrientation(
  _ first: CGPoint,
  _ second: CGPoint,
  _ third: CGPoint
) -> Int {
  let value =
    ((second.y - first.y) * (third.x - second.x))
    - ((second.x - first.x) * (third.y - second.y))
  if abs(value) < 0.001 {
    return 0
  }
  return value > 0 ? 1 : 2
}

private func policyCanvasPoint(
  _ point: CGPoint,
  liesOn start: CGPoint,
  to end: CGPoint,
  epsilon: CGFloat
) -> Bool {
  point.x <= max(start.x, end.x) + epsilon
    && point.x + epsilon >= min(start.x, end.x)
    && point.y <= max(start.y, end.y) + epsilon
    && point.y + epsilon >= min(start.y, end.y)
}
