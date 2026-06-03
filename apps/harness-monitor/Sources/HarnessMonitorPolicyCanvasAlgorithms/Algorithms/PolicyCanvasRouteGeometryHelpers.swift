import SwiftUI

public struct PolicyCanvasRouteFamilyPreference: Sendable {
  public let forcedTargetSide: PolicyCanvasPortSide?
  public let forcedSourceSide: PolicyCanvasPortSide?
  public let collapsesTargetFanoutLane: Bool

  public static let none = Self(
    forcedTargetSide: nil,
    forcedSourceSide: nil,
    collapsesTargetFanoutLane: false
  )

  public init(
    forcedTargetSide: PolicyCanvasPortSide?,
    forcedSourceSide: PolicyCanvasPortSide?,
    collapsesTargetFanoutLane: Bool
  ) {
    self.forcedTargetSide = forcedTargetSide
    self.forcedSourceSide = forcedSourceSide
    self.collapsesTargetFanoutLane = collapsesTargetFanoutLane
  }
}

public func policyCanvasRouteBuildOrder(
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
    let leftQuantized = policyCanvasQuantizedBuildOrderKey(
      span: leftKey.span,
      source: leftKey.source,
      target: leftKey.target
    )
    let rightQuantized = policyCanvasQuantizedBuildOrderKey(
      span: rightKey.span,
      source: rightKey.source,
      target: rightKey.target
    )
    if leftQuantized.span != rightQuantized.span {
      return leftQuantized.span < rightQuantized.span
    }
    if leftQuantized.sourceX != rightQuantized.sourceX {
      return leftQuantized.sourceX < rightQuantized.sourceX
    }
    if leftQuantized.sourceY != rightQuantized.sourceY {
      return leftQuantized.sourceY < rightQuantized.sourceY
    }
    if leftQuantized.targetX != rightQuantized.targetX {
      return leftQuantized.targetX < rightQuantized.targetX
    }
    if leftQuantized.targetY != rightQuantized.targetY {
      return leftQuantized.targetY < rightQuantized.targetY
    }
    return left.edge.id < right.edge.id
  }.map { $0.edge }
}

private struct PolicyCanvasQuantizedRouteBuildOrderKey {
  let span: Int
  let sourceX: Int
  let sourceY: Int
  let targetX: Int
  let targetY: Int
}

private func policyCanvasQuantizedBuildOrderKey(
  span: CGFloat,
  source: CGPoint,
  target: CGPoint
) -> PolicyCanvasQuantizedRouteBuildOrderKey {
  PolicyCanvasQuantizedRouteBuildOrderKey(
    span: Int((span * 1_000).rounded()),
    sourceX: Int((source.x * 1_000).rounded()),
    sourceY: Int((source.y * 1_000).rounded()),
    targetX: Int((target.x * 1_000).rounded()),
    targetY: Int((target.y * 1_000).rounded())
  )
}

public func policyCanvasLaneAssignments(
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

public func policyCanvasRouteFamilyPreferences(
  edges: [PolicyCanvasEdge],
  nodeFramesByID: [String: CGRect] = [:],
  nodeGroupIDsByID: [String: String?] = [:]
) -> [String: PolicyCanvasRouteFamilyPreference] {
  let sharedTargetCounts = Dictionary(grouping: edges, by: \.target).mapValues(\.count)
  // Distinct feeder nodes per target: a true multi-source fan-in (several
  // different nodes into one input port, e.g. every check's "missing" rail into
  // one human gate) versus a same-source parallel family.
  let distinctSourceNodeCounts = Dictionary(grouping: edges, by: \.target)
    .mapValues { Set($0.map(\.source.nodeID)).count }
  // Fan-out: a source whose outputs drop to three or more distinct nodes sitting
  // entirely below it. Those feeders leave the source's bottom edge and diverge
  // to their spread-out children in target order, instead of half of them exiting
  // trailing and wrapping back down (the action gate's mutate/unsafe arms). The
  // threshold is three because a wide two-way split (the risk gate, whose arms
  // straddle a third node parked between them) cannot all reach the bottom without
  // one rail threading between the row's nodes; a two-way split keeps geometry's
  // per-arm side. Counting distinct below-target NODES keeps a parallel family
  // (one merged wire) from inflating the fan-out.
  func targetBelowSource(_ edge: PolicyCanvasEdge) -> Bool {
    guard
      let sourceFrame = nodeFramesByID[edge.source.nodeID],
      let targetFrame = nodeFramesByID[edge.target.nodeID]
    else {
      return false
    }
    return targetFrame.minY > sourceFrame.maxY
  }
  let belowChildCounts = Dictionary(
    grouping: edges.filter(targetBelowSource),
    by: { $0.source.nodeID }
  ).mapValues { Set($0.map(\.target.nodeID)).count }
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
      // Collapsing the target fan-out lane to 0 packs every rail onto one shared
      // horizontal lane just above the node; the rails then reach that lane from
      // their own descent columns in a different order than their top markers,
      // so they cross. Only collapse when the feeders share a source node (their
      // descent columns coincide). A multi-source fan-in keeps per-rail fan-out
      // lanes so each rail descends in its own source-ordered column and the
      // rails land on their markers without crossing.
      let isMultiSourceFanIn = distinctSourceNodeCounts[edge.target, default: 1] >= 3
      let crossesGroupBoundary =
        nodeGroupIDsByID[edge.source.nodeID] != nodeGroupIDsByID[edge.target.nodeID]
      let forcedSourceSide: PolicyCanvasPortSide? =
        (belowChildCounts[edge.source.nodeID, default: 0] >= 3
          && targetBelowSource(edge)
          && !crossesGroupBoundary)
        ? .bottom : nil
      return (
        edge.id,
        PolicyCanvasRouteFamilyPreference(
          forcedTargetSide: forcesTopTargetSide ? .top : nil,
          forcedSourceSide: forcedSourceSide,
          collapsesTargetFanoutLane: forcesTopTargetSide && !isMultiSourceFanIn
        )
      )
    }
  )
}

/// Resolve a family's forced target side against actual node geometry. The
/// preference above forces top-side entry for a 3+ fan-in so rails stack above
/// the target. Once the comb pass lifts a shared collector ABOVE its sources the
/// feeders are below it, so a top approach overshoots the node and hooks back
/// down through its body. Enter from the bottom - the side facing the sources -
/// whenever the source node sits entirely below the target node.
public func policyCanvasGeometryAwareForcedTargetSide(
  forced: PolicyCanvasPortSide?,
  sourceFrame: CGRect?,
  targetFrame: CGRect?
) -> PolicyCanvasPortSide? {
  guard forced == .top,
    let sourceFrame,
    let targetFrame,
    sourceFrame.minY > targetFrame.maxY
  else {
    return forced
  }
  return .bottom
}

/// Resolve an output port's exit side against node geometry so an edge leaves
/// toward its target instead of always exiting trailing and wrapping back.
///
/// - A target sitting entirely above exits the top: the rail climbs straight up
///   (the lifted-collector fan-in).
/// - A target sitting entirely below AND not to the right exits the bottom: it
///   drops straight down or down-and-left without wrapping (risk's low-risk ->
///   auto-merge, which is down-left).
/// - A target below-and-to-the-right keeps the natural trailing exit. Forcing
///   bottom there only drags the rail through a long shared vertical corridor
///   (the action-gate default/unsafe outputs), which reads worse than a plain
///   trailing departure that turns down once it has cleared the node.
///
/// Mirrors `policyCanvasGeometryAwareForcedTargetSide` for the source endpoint.
public func policyCanvasGeometryAwareSourceSide(
  natural: PolicyCanvasPortSide,
  sourceFrame: CGRect?,
  targetFrame: CGRect?
) -> PolicyCanvasPortSide {
  guard natural == .trailing,
    let sourceFrame,
    let targetFrame
  else {
    return natural
  }
  if targetFrame.maxY < sourceFrame.minY {
    return .top
  }
  if targetFrame.minY > sourceFrame.maxY, targetFrame.midX <= sourceFrame.midX {
    return .bottom
  }
  return natural
}

/// Resolve an output edge's exit side, choosing between a collision-derived marker
/// terminal side and the geometric side.
///
/// The marker terminal side is inferred from whichever way the sequential router
/// happened to leave on an earlier convergence pass. For an ordinary edge that
/// inference is the better signal, so it wins. But for a member of a genuine
/// multi-source fan-in (three or more distinct nodes converging on one input port),
/// the rails must all leave toward the collector - its top once the comb lifts the
/// collector above its sources. There a definitive geometric side (the target
/// sitting entirely above, or entirely below and to the left) is authoritative: if
/// the collision router pins one rail's marker to the bottom instead, that rail
/// drops out of its source's bottom port and dives back up through the source row,
/// breaking the nest. So for a fan-in member, a definitive geometric side overrides
/// the terminal side; when geometry expresses no opinion (returns the natural
/// trailing side) the terminal side still wins, preserving router freedom.
public struct PolicyCanvasPreferredSourceSideInput: Sendable {
  public let fixedSide: PolicyCanvasPortSide?
  public let forcedFanOutSide: PolicyCanvasPortSide?
  public let terminalSide: PolicyCanvasPortSide?
  public let natural: PolicyCanvasPortSide
  public let isFanInMember: Bool
  public let sourceFrame: CGRect?
  public let targetFrame: CGRect?

  public init(
    fixedSide: PolicyCanvasPortSide?,
    forcedFanOutSide: PolicyCanvasPortSide?,
    terminalSide: PolicyCanvasPortSide?,
    natural: PolicyCanvasPortSide,
    isFanInMember: Bool,
    sourceFrame: CGRect?,
    targetFrame: CGRect?
  ) {
    self.fixedSide = fixedSide
    self.forcedFanOutSide = forcedFanOutSide
    self.terminalSide = terminalSide
    self.natural = natural
    self.isFanInMember = isFanInMember
    self.sourceFrame = sourceFrame
    self.targetFrame = targetFrame
  }
}

public func policyCanvasPreferredSourceSide(
  input: PolicyCanvasPreferredSourceSideInput
) -> PolicyCanvasPortSide {
  let geometrySide = policyCanvasGeometryAwareSourceSide(
    natural: input.natural,
    sourceFrame: input.sourceFrame,
    targetFrame: input.targetFrame
  )
  if let fixedSide = input.fixedSide {
    return fixedSide
  }
  // A fan-out feeder leaves its source's bottom edge regardless of whether its
  // child sits below-and-left (geometry's bottom) or below-and-right (geometry's
  // trailing), so the whole fan diverges from one edge instead of splitting half
  // to a trailing wrap.
  if let forcedFanOutSide = input.forcedFanOutSide {
    return forcedFanOutSide
  }
  if input.isFanInMember, geometrySide != input.natural {
    return geometrySide
  }
  return input.terminalSide ?? geometrySide
}

/// Resolve an input port's entry side against node geometry so an edge enters
/// from the side facing its source instead of being free to wrap to the far side.
///
/// - A source sitting entirely above enters the top: the rail drops straight in,
///   and the final handoff lands just above the node rather than wrapping below
///   it. This is the universal mirror of an output exiting toward its target; it
///   also stops a freshly admitted bottom anchor (needed for a lifted-collector
///   fan-in) from being chosen for an ordinary top-down edge whose target happens
///   to sit beneath an obstacle.
/// - Otherwise it returns nil, leaving the entry side unconstrained so the
///   flexible router keeps choosing the cleanest approach (a same-row edge enters
///   head-on, a multi-source fan-in from below is steered to the bottom by the
///   forced-side path). Returning a concrete side here would pin every ordinary
///   input to one side and reintroduce terminal jogs the router otherwise avoids.
///
/// Mirrors `policyCanvasGeometryAwareSourceSide` for the target endpoint, but only
/// expresses a preference when geometry demands it.
public func policyCanvasGeometryAwareTargetSide(
  sourceFrame: CGRect?,
  targetFrame: CGRect?
) -> PolicyCanvasPortSide? {
  guard let sourceFrame,
    let targetFrame,
    sourceFrame.maxY < targetFrame.minY
  else {
    return nil
  }
  let verticalGap = targetFrame.minY - sourceFrame.maxY
  let horizontalSpan = abs(targetFrame.midX - sourceFrame.midX)
  guard verticalGap >= horizontalSpan else {
    return nil
  }
  return .top
}

/// Order a target fan-in so its feeder lanes nest instead of crossing. Lane 0
/// sits nearest the target; the source farthest from the target's center (the
/// outermost rail on either side) takes it, and closer sources fall to lanes
/// farther out. Because the left rails stay left of the target center and the
/// right rails stay right of it, mirroring the nesting on both sides keeps every
/// horizontal feeder clear of the other rails' vertical risers. Sorting by raw
/// source x instead (the previous behavior) nests one side but inverts the
/// other, so the far side's feeders cross. Shared by both route paths.
public func policyCanvasTargetFanoutNestingSortKey(
  bucket: String,
  sourceX: CGFloat,
  targetCenterX: CGFloat,
  sourceY: CGFloat,
  edgeID: String
) -> String {
  let distance = Int(abs(sourceX - targetCenterX).rounded())
  let nesting = String(format: "%09d", max(0, 999_999_999 - distance))
  return [bucket, nesting, String(Int(sourceY.rounded())), edgeID].joined(separator: "|")
}

public func policyCanvasSharedTargetRouteLaneAssignments(
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

public func policyCanvasTargetFanoutLaneAssignments(
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

public func policyCanvasPreferredRouteAnchorCandidates(
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
