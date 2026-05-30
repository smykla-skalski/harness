import SwiftUI

struct PolicyCanvasRouteFamilyPreference {
  let forcedTargetSide: PolicyCanvasPortSide?
  let collapsesTargetFanoutLane: Bool

  static let none = Self(
    forcedTargetSide: nil,
    collapsesTargetFanoutLane: false
  )
}

func policyCanvasRouteBuildOrder(
  edges: [PolicyCanvasEdge],
  portAnchors: [PolicyCanvasPortEndpoint: CGPoint]
) -> [PolicyCanvasEdge] {
  let keyedEdges = edges.map { edge in
    (
      edge: edge,
      key: policyCanvasRouteBuildSortValues(edge: edge, portAnchors: portAnchors)
    )
  }
  return keyedEdges.sorted { left, right in
    let leftKey = left.key
    let rightKey = right.key
    if abs(leftKey.span - rightKey.span) > 0.001 {
      return leftKey.span < rightKey.span
    }
    if abs(leftKey.source.x - rightKey.source.x) > 0.001 {
      return leftKey.source.x < rightKey.source.x
    }
    if abs(leftKey.source.y - rightKey.source.y) > 0.001 {
      return leftKey.source.y < rightKey.source.y
    }
    if abs(leftKey.target.x - rightKey.target.x) > 0.001 {
      return leftKey.target.x < rightKey.target.x
    }
    if abs(leftKey.target.y - rightKey.target.y) > 0.001 {
      return leftKey.target.y < rightKey.target.y
    }
    return left.edge.id < right.edge.id
  }.map { $0.edge }
}

func policyCanvasLaneAssignments(
  edges: [PolicyCanvasEdge],
  bucket: (PolicyCanvasEdge) -> String,
  sortKey: (PolicyCanvasEdge) -> String
) -> [String: Int] {
  let sortedEdges = policyCanvasSortedEdges(edges, sortKey: sortKey)
  var nextLaneByBucket: [String: Int] = [:]
  var lanes: [String: Int] = [:]
  for edge in sortedEdges {
    let edgeBucket = bucket(edge)
    let lane = nextLaneByBucket[edgeBucket, default: 0]
    lanes[edge.id] = lane
    nextLaneByBucket[edgeBucket] = lane + 1
  }
  return lanes
}

func policyCanvasRouteFamilyPreferences(
  edges: [PolicyCanvasEdge]
) -> [String: PolicyCanvasRouteFamilyPreference] {
  let sharedTargetCounts = Dictionary(grouping: edges, by: \.target).mapValues(\.count)
  return Dictionary(
    uniqueKeysWithValues: edges.map { edge in
      let sharedTargetCount = sharedTargetCounts[edge.target, default: 1]
      // A genuine multi-source fan-in (three or more edges into one input port)
      // forces top-side entry so the rails stack above the target instead of
      // crowding its leading edge. Same-endpoint parallel families fold into one
      // merged wire on load, so they never reach here as a family.
      let forcesTopTargetSide =
        edge.target.kind == .input
        && edge.target.side == nil
        && sharedTargetCount >= 3
      return (
        edge.id,
        PolicyCanvasRouteFamilyPreference(
          forcedTargetSide: forcesTopTargetSide ? .top : nil,
          collapsesTargetFanoutLane: forcesTopTargetSide
        )
      )
    }
  )
}

func policyCanvasSharedTargetRouteLaneAssignments(
  edges: [PolicyCanvasEdge],
  bucket: (PolicyCanvasEdge) -> String,
  sortKey: (PolicyCanvasEdge) -> String
) -> [String: Int] {
  let sortedEdges = policyCanvasSortedEdges(edges, sortKey: sortKey)
  var nextLaneByBucket: [String: Int] = [:]
  var lanes: [String: Int] = [:]
  for edge in sortedEdges {
    let edgeBucket = bucket(edge)
    let lane = nextLaneByBucket[edgeBucket, default: 0]
    lanes[edge.id] = lane
    nextLaneByBucket[edgeBucket] = lane + 1
  }
  return lanes
}

func policyCanvasTargetFanoutLaneAssignments(
  edges: [PolicyCanvasEdge],
  familyPreferences: [String: PolicyCanvasRouteFamilyPreference],
  bucket: (PolicyCanvasEdge) -> String,
  sortKey: (PolicyCanvasEdge) -> String
) -> [String: Int] {
  var lanes = policyCanvasLaneAssignments(
    edges: edges,
    bucket: bucket,
    sortKey: sortKey
  )
  for edge in edges where familyPreferences[edge.id, default: .none].collapsesTargetFanoutLane {
    lanes[edge.id] = 0
  }
  return lanes
}

func policyCanvasPreferredRouteAnchorCandidates(
  _ candidates: [PolicyCanvasRouteAnchorCandidate],
  preferredSide: PolicyCanvasPortSide?
) -> [PolicyCanvasRouteAnchorCandidate] {
  guard let preferredSide else {
    return candidates
  }
  let preferredCandidates = candidates.filter { $0.side == preferredSide }
  return preferredCandidates.isEmpty ? candidates : preferredCandidates
}

private func policyCanvasSortedEdges(
  _ edges: [PolicyCanvasEdge],
  sortKey: (PolicyCanvasEdge) -> String
) -> [PolicyCanvasEdge] {
  let keyedEdges = edges.map { edge in
    (edge: edge, key: sortKey(edge))
  }
  return keyedEdges.sorted { left, right in
    if left.key != right.key {
      return left.key < right.key
    }
    return left.edge.id < right.edge.id
  }.map { $0.edge }
}
