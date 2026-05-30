import SwiftUI

struct PolicyCanvasRouteFamilyPreference {
  let forcedTargetSide: PolicyCanvasPortSide?
  let prefersBottomSourceSideWhenTargetBelow: Bool
  let collapsesSourceTerminal: Bool
  let collapsesSourceFanoutLane: Bool
  let collapsesTargetFanoutLane: Bool

  static let none = Self(
    forcedTargetSide: nil,
    prefersBottomSourceSideWhenTargetBelow: false,
    collapsesSourceTerminal: false,
    collapsesSourceFanoutLane: false,
    collapsesTargetFanoutLane: false
  )
}

private struct PolicyCanvasParallelRouteFamilyKey: Hashable {
  let source: PolicyCanvasPortEndpoint
  let target: PolicyCanvasPortEndpoint
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
  let parallelCounts = Dictionary(
    grouping: edges,
    by: { PolicyCanvasParallelRouteFamilyKey(source: $0.source, target: $0.target) }
  )
  .mapValues(\.count)
  return Dictionary(
    uniqueKeysWithValues: edges.map { edge in
      let sharedTargetCount = sharedTargetCounts[edge.target, default: 1]
      let parallelCount = parallelCounts[
        PolicyCanvasParallelRouteFamilyKey(source: edge.source, target: edge.target),
        default: 1
      ]
      let forcesTopTargetSide =
        edge.target.kind == .input
        && edge.target.side == nil
        && (parallelCount > 1 || sharedTargetCount >= 3)
      let prefersBottomSourceSideWhenTargetBelow =
        forcesTopTargetSide
        && parallelCount > 1
        && edge.source.kind == .output
        && edge.source.side == nil
      let forcedTargetSide: PolicyCanvasPortSide? =
        forcesTopTargetSide ? .top : nil
      return (
        edge.id,
        PolicyCanvasRouteFamilyPreference(
          forcedTargetSide: forcedTargetSide,
          prefersBottomSourceSideWhenTargetBelow: prefersBottomSourceSideWhenTargetBelow,
          // Distinctly-labelled parallel edges keep their own source dot. The
          // source terminal and fanout lane no longer collapse onto a single
          // shared marker - each edge attaches at its own point, mirroring the
          // separate-anchor behaviour already used on the target side.
          collapsesSourceTerminal: false,
          collapsesSourceFanoutLane: false,
          collapsesTargetFanoutLane: forcesTopTargetSide
        )
      )
    }
  )
}

func policyCanvasPreferredFamilySourceSide(
  edge: PolicyCanvasEdge,
  familyPreference: PolicyCanvasRouteFamilyPreference,
  source: CGPoint,
  target: CGPoint
) -> PolicyCanvasPortSide? {
  guard
    familyPreference.prefersBottomSourceSideWhenTargetBelow,
    edge.source.kind == .output,
    edge.source.side == nil,
    target.y >= source.y + PolicyCanvasLayout.nodeSize.height
  else {
    return nil
  }
  return .bottom
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

func policyCanvasSourceFanoutLaneAssignments(
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
  for edge in edges where familyPreferences[edge.id, default: .none].collapsesSourceFanoutLane {
    lanes[edge.id] = 0
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

func policyCanvasResolvedSourceTerminalSlot(
  _ slot: PolicyCanvasRouteEndpointSlot,
  familyPreference: PolicyCanvasRouteFamilyPreference
) -> PolicyCanvasRouteEndpointSlot {
  familyPreference.collapsesSourceTerminal ? .single : slot
}

func policyCanvasCollapsedSourceTerminalGroup(
  edge: PolicyCanvasEdge,
  familyPreference: PolicyCanvasRouteFamilyPreference
) -> String? {
  guard familyPreference.collapsesSourceTerminal else {
    return nil
  }
  return [
    edge.source.nodeID,
    edge.source.portID,
    edge.target.nodeID,
    edge.target.portID,
  ]
  .joined(separator: "|")
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
