// ELK JSON parsing helpers and layout-metrics computation extracted from
// PolicyCanvasElkLayoutEngine to satisfy the file-length limit.
import CoreGraphics
import Foundation

func elkDouble(_ value: Any?) -> CGFloat? {
  if let double = value as? Double {
    return CGFloat(double)
  }
  if let int = value as? Int {
    return CGFloat(int)
  }
  if let number = value as? NSNumber {
    return CGFloat(truncating: number)
  }
  if let string = value as? String, let double = Double(string) {
    return CGFloat(double)
  }
  return nil
}

func elkPoint(_ value: Any?) -> CGPoint? {
  guard let dictionary = value as? [String: Any],
    let x = elkDouble(dictionary["x"]),
    let y = elkDouble(dictionary["y"])
  else {
    return nil
  }
  return snappedLayoutPoint(CGPoint(x: x, y: y))
}

func policyCanvasElkLayoutMetrics(
  graph: PolicyCanvasLayoutGraph,
  nodePositions: [String: CGPoint],
  nodeSizes: [String: CGSize],
  groupRanks: [String: Int],
  layoutGroupIDByNodeID: [String: String]
) -> PolicyCanvasLayoutMetrics {
  let nodeCenters = Dictionary(
    uniqueKeysWithValues: graph.nodes.compactMap { node -> (String, CGPoint)? in
      guard let position = nodePositions[node.id] else {
        return nil
      }
      let frame = CGRect(origin: position, size: nodeSizes[node.id] ?? PolicyCanvasLayout.nodeSize)
      return (node.id, CGPoint(x: frame.midX, y: frame.midY))
    }
  )
  var flowDirectionViolations = 0
  var edgeLengths: [Double] = []
  edgeLengths.reserveCapacity(graph.edges.count)
  var crossGroupOrderViolations = 0
  for edge in graph.edges {
    if let sourceGroupID = layoutGroupIDByNodeID[edge.sourceNodeID],
      let targetGroupID = layoutGroupIDByNodeID[edge.targetNodeID],
      sourceGroupID != targetGroupID,
      let sourceRank = groupRanks[sourceGroupID],
      let targetRank = groupRanks[targetGroupID],
      sourceRank > targetRank
    {
      crossGroupOrderViolations += 1
    }
    guard
      let sourceCenter = nodeCenters[edge.sourceNodeID],
      let targetCenter = nodeCenters[edge.targetNodeID]
    else {
      continue
    }
    if targetCenter.x + 1 < sourceCenter.x {
      flowDirectionViolations += 1
    }
    edgeLengths.append(
      hypot(
        Double(targetCenter.x - sourceCenter.x),
        Double(targetCenter.y - sourceCenter.y)
      )
    )
  }
  let averageEdgeLength =
    edgeLengths.isEmpty ? 0 : edgeLengths.reduce(0, +) / Double(edgeLengths.count)
  let edgeLengthVariance =
    edgeLengths.isEmpty
    ? 0
    : edgeLengths.reduce(into: 0) { partial, length in
      let delta = length - averageEdgeLength
      partial += delta * delta
    } / Double(edgeLengths.count)
  let normalizedLengthVariance =
    averageEdgeLength > 0
    ? edgeLengthVariance / max(1.0, averageEdgeLength * averageEdgeLength)
    : 0
  let readabilityScore = max(
    0,
    1_000
      - Double(flowDirectionViolations * 80)
      - Double(crossGroupOrderViolations * 120)
      - (normalizedLengthVariance * 100)
  )
  return PolicyCanvasLayoutMetrics(
    macroLayerCount: Set(groupRanks.values).count,
    crossGroupOrderViolations: crossGroupOrderViolations,
    anchoredNodeCount: graph.nodes.reduce(into: 0) { count, node in
      if node.anchor != nil {
        count += 1
      }
    },
    edgeCrossingCount: 0,
    flowDirectionViolationCount: flowDirectionViolations,
    averageEdgeLength: averageEdgeLength,
    edgeLengthVariance: edgeLengthVariance,
    readabilityScore: readabilityScore
  )
}
