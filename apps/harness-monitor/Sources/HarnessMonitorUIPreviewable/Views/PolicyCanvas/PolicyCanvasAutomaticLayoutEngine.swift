import Foundation
import SwiftUI

enum PolicyCanvasAutomaticLayoutMode: Sendable, Equatable {
  case initialLoad
  case explicitReflow(preserveManualAnchors: Bool)

  var preservesManualAnchors: Bool {
    switch self {
    case .initialLoad:
      false
    case .explicitReflow(let preserveManualAnchors):
      preserveManualAnchors
    }
  }

  var centersInMinimumCanvas: Bool {
    switch self {
    case .initialLoad:
      true
    case .explicitReflow(let preserveManualAnchors):
      !preserveManualAnchors
    }
  }

  var seedsOrderHintsFromCurrentGeometry: Bool {
    switch self {
    case .initialLoad:
      true
    case .explicitReflow(let preserveManualAnchors):
      // Reflow that preserves anchors is meant to massage the existing
      // arrangement, so the geometric order seed should also survive.
      // Reflow that drops anchors is the user asking for a fresh layout
      // and falls back to originalIndex order.
      preserveManualAnchors
    }
  }
}

struct PolicyCanvasLayoutGraph: Sendable {
  var nodes: [PolicyCanvasLayoutNode]
  var edges: [PolicyCanvasLayoutEdge]
  var groups: [PolicyCanvasLayoutGroup]
}

struct PolicyCanvasLayoutNode: Identifiable, Sendable {
  let id: String
  let groupID: String?
  let originalIndex: Int
  let currentPosition: CGPoint
  let anchor: PolicyCanvasLayoutAnchor?
}

struct PolicyCanvasLayoutAnchor: Equatable, Sendable {
  let position: CGPoint
}

struct PolicyCanvasLayoutEdge: Identifiable, Sendable {
  let id: String
  let sourceNodeID: String
  let targetNodeID: String
}

struct PolicyCanvasLayoutGroup: Identifiable, Sendable {
  let id: String
  let originalIndex: Int
  let memberNodeIDs: [String]
}

struct PolicyCanvasLayoutMetrics: Equatable, Sendable {
  let macroLayerCount: Int
  let crossGroupOrderViolations: Int
  let anchoredNodeCount: Int
  let edgeCrossingCount: Int
  let flowDirectionViolationCount: Int
  let averageEdgeLength: Double
  let edgeLengthVariance: Double
  let readabilityScore: Double
}

struct PolicyCanvasRouteCorridorKey: Equatable, Hashable, Sendable {
  let sourceScopeID: String
  let targetScopeID: String
  let laneIndex: Int
}

struct PolicyCanvasEdgeCorridorHint: Equatable, Hashable, Sendable {
  let key: PolicyCanvasRouteCorridorKey
  let horizontalLaneY: CGFloat
  let verticalLaneX: CGFloat?
}

struct PolicyCanvasLayoutRoutingHints: Equatable, Hashable, Sendable {
  let edgeHints: [String: PolicyCanvasEdgeCorridorHint]

  static let empty = Self(edgeHints: [:])

  var isEmpty: Bool {
    edgeHints.isEmpty
  }

  func edgeHint(for edgeID: String) -> PolicyCanvasEdgeCorridorHint? {
    edgeHints[edgeID]
  }

  func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
    guard dx != 0 || dy != 0 else {
      return self
    }
    return Self(
      edgeHints: edgeHints.mapValues { hint in
        PolicyCanvasEdgeCorridorHint(
          key: hint.key,
          horizontalLaneY: hint.horizontalLaneY + dy,
          verticalLaneX: hint.verticalLaneX.map { $0 + dx }
        )
      }
    )
  }
}

struct PolicyCanvasLayoutResult: Sendable {
  let nodePositions: [String: CGPoint]
  let groupFrames: [String: CGRect]
  let autoPlacedNodeIDs: Set<String>
  let metrics: PolicyCanvasLayoutMetrics
  let routingHints: PolicyCanvasLayoutRoutingHints?
}

struct PolicyCanvasLayoutConfiguration: Sendable {
  let interGroupSpacing: CGFloat
  let columnSpacing: CGFloat
  let rowSpacing: CGFloat
  let targetGroupAspectRatio: CGFloat
  let sweepPassCount: Int

  var columnStep: CGFloat {
    PolicyCanvasLayout.nodeSize.width + columnSpacing
  }

  var rowStep: CGFloat {
    PolicyCanvasLayout.nodeSize.height + rowSpacing
  }

  static let layeredDefault = Self(
    interGroupSpacing: 220,
    columnSpacing: 140,
    rowSpacing: 140,
    targetGroupAspectRatio: 2,
    sweepPassCount: 12
  )
}

protocol PolicyCanvasLayoutEngine {
  func layout(
    graph: PolicyCanvasLayoutGraph,
    configuration: PolicyCanvasLayoutConfiguration
  ) -> PolicyCanvasLayoutResult?
}

struct PolicyCanvasLayeredOrderingItem: Identifiable, Equatable {
  let id: String
  let realNodeID: String?
  let rank: Int

  var isDummy: Bool {
    realNodeID == nil
  }
}

struct PolicyCanvasLayeredOrderingGraph {
  let itemsByID: [String: PolicyCanvasLayeredOrderingItem]
  let layers: [[String]]
  let incoming: [String: [String]]
  let outgoing: [String: [String]]
}

struct PolicyCanvasLayeredLayoutEngine: PolicyCanvasLayoutEngine {
  let mode: PolicyCanvasAutomaticLayoutMode

  init(mode: PolicyCanvasAutomaticLayoutMode = .initialLoad) {
    self.mode = mode
  }

  func layout(
    graph: PolicyCanvasLayoutGraph,
    configuration: PolicyCanvasLayoutConfiguration = .layeredDefault
  ) -> PolicyCanvasLayoutResult? {
    guard !graph.nodes.isEmpty else {
      return nil
    }

    let normalizedGroups = normalizedGroups(for: graph)
    let nodesByID = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
    let layoutGroupIDByNodeID = Dictionary(
      uniqueKeysWithValues: normalizedGroups.flatMap { group in
        group.nodeIDs.map { ($0, group.layoutID) }
      }
    )
    let anchoredNodeIDs = Set(
      graph.nodes.compactMap { node in
        node.anchor == nil ? nil : node.id
      })
    let acyclicNodeEdges = policyCanvasAcyclicEdges(
      ids: graph.nodes.map(\.id),
      originalOrder: Dictionary(
        uniqueKeysWithValues: graph.nodes.map { ($0.id, $0.originalIndex) }),
      edges: graph.edges
    )
    let groupRanks = groupRanks(
      for: normalizedGroups,
      edges: acyclicNodeEdges,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID
    )
    let internalRanks = internalRanks(
      for: normalizedGroups,
      edges: acyclicNodeEdges,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID
    )

    if anchoredNodeIDs.isEmpty {
      return unconstrainedLayeredLayout(
        graph: graph,
        normalizedGroups: normalizedGroups,
        layoutGroupIDByNodeID: layoutGroupIDByNodeID,
        groupRanks: groupRanks,
        internalRanks: internalRanks,
        acyclicNodeEdges: acyclicNodeEdges,
        nodesByID: nodesByID,
        configuration: configuration
      )
    }

    let anchoredMinXByGroup = anchoredMinXByGroup(
      nodesByID: nodesByID,
      normalizedGroups: normalizedGroups
    )
    let groupOrder = orderedGroups(
      normalizedGroups: normalizedGroups,
      groupRanks: groupRanks,
      anchoredMinXByGroup: anchoredMinXByGroup
    )
    var orderHints = initialOrderHints(
      normalizedGroups: normalizedGroups,
      nodesByID: nodesByID,
      edges: acyclicNodeEdges
    )
    for _ in 0..<configuration.sweepPassCount {
      sweepOrderHints(
        groups: groupOrder,
        graph: PolicyCanvasLayoutGraph(
          nodes: graph.nodes,
          edges: acyclicNodeEdges,
          groups: graph.groups
        ),
        layoutGroupIDByNodeID: layoutGroupIDByNodeID,
        internalRanks: internalRanks,
        preferIncomingNeighbors: true,
        orderHints: &orderHints
      )
      sweepOrderHints(
        groups: groupOrder.reversed(),
        graph: PolicyCanvasLayoutGraph(
          nodes: graph.nodes,
          edges: acyclicNodeEdges,
          groups: graph.groups
        ),
        layoutGroupIDByNodeID: layoutGroupIDByNodeID,
        internalRanks: internalRanks,
        preferIncomingNeighbors: false,
        orderHints: &orderHints
      )
    }

    var nodePositions: [String: CGPoint] = [:]
    var groupFrames: [String: CGRect] = [:]
    var groupFramesByLayoutID: [String: CGRect] = [:]
    var autoPlacedNodeIDs: Set<String> = []
    var anchoredGroupIDs: Set<String> = []
    var nextAutoGroupMinX: CGFloat = 0

    for group in groupOrder {
      let memberIDs = group.nodeIDs.filter { nodesByID[$0] != nil }
      guard !memberIDs.isEmpty else {
        continue
      }

      let anchoredMembers = memberIDs.filter { anchoredNodeIDs.contains($0) }
      if !anchoredMembers.isEmpty {
        anchoredGroupIDs.insert(group.layoutID)
      }
      let anchoredFrames = anchoredMembers.compactMap { nodeID -> CGRect? in
        guard let anchor = nodesByID[nodeID]?.anchor else {
          return nil
        }
        let position = snappedLayoutPoint(anchor.position)
        nodePositions[nodeID] = position
        return CGRect(origin: position, size: PolicyCanvasLayout.nodeSize)
      }

      let groupOrigin = CGPoint(
        x: anchoredMembers.compactMap { nodesByID[$0]?.anchor?.position.x }.min()
          .map { $0 - PolicyCanvasLayout.groupHorizontalPadding } ?? nextAutoGroupMinX,
        y: anchoredMembers.compactMap { nodesByID[$0]?.anchor?.position.y }.min()
          .map { $0 - PolicyCanvasLayout.groupVerticalPadding } ?? 0
      )
      let orderedFreeMembers = orderedFreeMembers(
        in: group,
        anchoredNodeIDs: anchoredNodeIDs,
        internalRanks: internalRanks,
        orderHints: orderHints
      )
      let placement = placeFreeMembers(
        orderedFreeMembers,
        internalRanks: internalRanks,
        groupOrigin: groupOrigin,
        reservedFrames: anchoredFrames,
        configuration: configuration
      )
      nodePositions.merge(placement.positions) { _, new in new }
      autoPlacedNodeIDs.formUnion(orderedFreeMembers)

      let memberBounds = memberIDs.reduce(CGRect.null) { partial, nodeID in
        guard let position = nodePositions[nodeID] else {
          return partial
        }
        return partial.union(CGRect(origin: position, size: PolicyCanvasLayout.nodeSize))
      }
      guard !memberBounds.isNull else {
        continue
      }

      let placementFrame: CGRect
      if let actualGroupID = group.actualGroupID {
        let frame = policyCanvasGroupFrame(containing: memberBounds)
        groupFrames[actualGroupID] = frame
        placementFrame = frame
      } else {
        placementFrame = memberBounds.integral
      }
      groupFramesByLayoutID[group.layoutID] = placementFrame
      nextAutoGroupMinX = max(
        nextAutoGroupMinX,
        placementFrame.maxX + configuration.interGroupSpacing
      )
    }

    balanceGroupVerticalPositions(
      groups: groupOrder,
      graph: graph,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID,
      anchoredGroupIDs: anchoredGroupIDs,
      nodePositions: &nodePositions,
      groupFramesByLayoutID: &groupFramesByLayoutID,
      groupFrames: &groupFrames,
      configuration: configuration
    )

    let metrics = policyCanvasMeasureLayoutMetrics(
      graph: graph,
      nodePositions: nodePositions,
      groupRanks: groupRanks,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID
    )
    let routingHints = policyCanvasLayoutRoutingHints(
      graph: graph,
      nodePositions: nodePositions,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID,
      groupFramesByLayoutID: groupFramesByLayoutID
    )
    return PolicyCanvasLayoutResult(
      nodePositions: nodePositions,
      groupFrames: groupFrames,
      autoPlacedNodeIDs: autoPlacedNodeIDs,
      metrics: metrics,
      routingHints: routingHints
    )
  }
}

private struct PolicyCanvasNormalizedLayoutGroup {
  let layoutID: String
  let actualGroupID: String?
  let originalIndex: Int
  var nodeIDs: [String]
}

private func policyCanvasLayoutRoutingHints(
  graph: PolicyCanvasLayoutGraph,
  nodePositions: [String: CGPoint],
  layoutGroupIDByNodeID: [String: String],
  groupFramesByLayoutID: [String: CGRect]
) -> PolicyCanvasLayoutRoutingHints? {
  let horizontalLaneCandidates = policyCanvasHorizontalCorridorLaneCandidates(
    nodePositions: nodePositions
  )
  guard !horizontalLaneCandidates.isEmpty else {
    return nil
  }

  var bundleEntries: [PolicyCanvasCorridorBundleEntry] = []
  bundleEntries.reserveCapacity(graph.edges.count)
  for edge in graph.edges {
    guard
      let sourcePosition = nodePositions[edge.sourceNodeID],
      let targetPosition = nodePositions[edge.targetNodeID]
    else {
      continue
    }
    let sourceScopeID = layoutGroupIDByNodeID[edge.sourceNodeID] ?? edge.sourceNodeID
    let targetScopeID = layoutGroupIDByNodeID[edge.targetNodeID] ?? edge.targetNodeID
    let sourceAnchor = CGPoint(
      x: sourcePosition.x + (PolicyCanvasLayout.nodeSize.width / 2),
      y: sourcePosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
    )
    let targetAnchor = CGPoint(
      x: targetPosition.x + (PolicyCanvasLayout.nodeSize.width / 2),
      y: targetPosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
    )
    let desiredLaneY = snappedLayoutDelta((sourceAnchor.y + targetAnchor.y) / 2)
    let preferredBand = policyCanvasPreferredTargetCorridorBand(
      sourceScopeID: sourceScopeID,
      targetScopeID: targetScopeID,
      targetNodeID: edge.targetNodeID,
      nodePositions: nodePositions,
      groupFramesByLayoutID: groupFramesByLayoutID
    )
    let resolvedLane = policyCanvasNearestHorizontalCorridorLane(
      desiredY: desiredLaneY,
      candidates: horizontalLaneCandidates,
      preferredBand: preferredBand
    )
    bundleEntries.append(
      PolicyCanvasCorridorBundleEntry(
        edgeID: edge.id,
        key: PolicyCanvasRouteCorridorKey(
          sourceScopeID: sourceScopeID,
          targetScopeID: targetScopeID,
          laneIndex: resolvedLane.index
        ),
        baseHorizontalLaneY: resolvedLane.y,
        verticalLaneX: policyCanvasPreferredVerticalCorridorLane(
          sourceScopeID: sourceScopeID,
          targetScopeID: targetScopeID,
          sourceNodeID: edge.sourceNodeID,
          targetNodeID: edge.targetNodeID,
          nodePositions: nodePositions,
          groupFramesByLayoutID: groupFramesByLayoutID
        ),
        targetNodeID: edge.targetNodeID,
        targetBand: preferredBand,
        stableTiebreak: policyCanvasCorridorBundleTiebreak(
          sourceAnchor: sourceAnchor,
          targetAnchor: targetAnchor,
          sourceNodeID: edge.sourceNodeID,
          targetNodeID: edge.targetNodeID,
          edgeID: edge.id
        )
      )
    )
  }
  let edgeHints = policyCanvasAssignCorridorBundleHints(entries: bundleEntries)
  guard !edgeHints.isEmpty else {
    return nil
  }
  return PolicyCanvasLayoutRoutingHints(edgeHints: edgeHints)
}

func policyCanvasHorizontalCorridorLaneCandidates(
  nodePositions: [String: CGPoint]
) -> [(index: Int, y: CGFloat)] {
  let nodeCenterYs = Set(
    nodePositions.values.map { position in
      snappedLayoutDelta(position.y + (PolicyCanvasLayout.nodeSize.height / 2))
    }
  ).sorted()
  guard !nodeCenterYs.isEmpty else {
    return []
  }
  // Clearance pad so lanes don't run through node bodies. Half the node
  // height plus one grid step lands the lane safely outside the node's
  // vertical extent.
  let clearance = (PolicyCanvasLayout.nodeSize.height / 2) + PolicyCanvasLayout.gridSize

  var lanes: [CGFloat] = []
  if nodeCenterYs.count == 1, let only = nodeCenterYs.first {
    // Single node: route above or below it, never through it.
    lanes = [
      snappedLayoutDelta(only - clearance),
      snappedLayoutDelta(only + clearance),
    ]
  } else {
    for (upper, lower) in zip(nodeCenterYs, nodeCenterYs.dropFirst()) {
      guard lower - upper > PolicyCanvasLayout.nodeSize.height / 2 else {
        continue
      }
      lanes.append(snappedLayoutDelta((upper + lower) / 2))
    }
    if lanes.isEmpty, let top = nodeCenterYs.first, let bottom = nodeCenterYs.last {
      // Cluster too tight for any mid-gap lane. Earlier code fell back to
      // the node centers themselves, which routed edges through node
      // bodies. Offer outside-the-cluster lanes instead so routes go
      // around the cluster rather than through it.
      lanes = [
        snappedLayoutDelta(top - clearance),
        snappedLayoutDelta(bottom + clearance),
      ]
    }
  }
  return Array(lanes.enumerated()).map { (index: $0.offset, y: $0.element) }
}

private func policyCanvasPreferredTargetCorridorBand(
  sourceScopeID: String,
  targetScopeID: String,
  targetNodeID: String,
  nodePositions: [String: CGPoint],
  groupFramesByLayoutID: [String: CGRect]
) -> ClosedRange<CGFloat>? {
  guard sourceScopeID != targetScopeID else {
    return nil
  }
  if let targetPosition = nodePositions[targetNodeID] {
    let targetFrame = CGRect(origin: targetPosition, size: PolicyCanvasLayout.nodeSize)
    return (targetFrame.minY - (PolicyCanvasLayout.gridSize * 3))...targetFrame.maxY
  }
  guard let targetFrame = groupFramesByLayoutID[targetScopeID] else {
    return nil
  }
  return targetFrame.minY...targetFrame.maxY
}

func policyCanvasNearestHorizontalCorridorLane(
  desiredY: CGFloat,
  candidates: [(index: Int, y: CGFloat)],
  preferredBand: ClosedRange<CGFloat>?
) -> (index: Int, y: CGFloat) {
  let preferredCandidates: [(index: Int, y: CGFloat)]
  if let preferredBand {
    let inBand = candidates.filter { preferredBand.contains($0.y) }
    if inBand.isEmpty {
      // No real candidate sits inside the target band. Snap the band centre
      // onto the layout grid, clamp it back inside the band, and derive the
      // laneIndex from that clamped y. The y/index pair is then tied to the
      // band, so two different targets get distinct laneIndex values (the
      // PolicyCanvasRouteCorridorKey identity stays per-target) while the
      // hint y always falls inside the target's band.
      let bandCenter = (preferredBand.lowerBound + preferredBand.upperBound) / 2
      let snappedCenter = snappedLayoutDelta(bandCenter)
      let clampedY = min(max(snappedCenter, preferredBand.lowerBound), preferredBand.upperBound)
      return (index: Int(clampedY.rounded()), y: clampedY)
    }
    preferredCandidates = inBand
  } else {
    preferredCandidates = candidates
  }
  return preferredCandidates.min { left, right in
    let leftDistance = abs(left.y - desiredY)
    let rightDistance = abs(right.y - desiredY)
    if abs(leftDistance - rightDistance) > 0.001 {
      return leftDistance < rightDistance
    }
    return left.index < right.index
  } ?? candidates[0]
}

private func policyCanvasPreferredVerticalCorridorLane(
  sourceScopeID: String,
  targetScopeID: String,
  sourceNodeID: String,
  targetNodeID: String,
  nodePositions: [String: CGPoint],
  groupFramesByLayoutID: [String: CGRect]
) -> CGFloat? {
  guard
    let sourceFrame = groupFramesByLayoutID[sourceScopeID],
    let targetFrame = groupFramesByLayoutID[targetScopeID]
  else {
    return nil
  }
  if sourceFrame.maxX <= targetFrame.minX {
    if let localizedLane = policyCanvasLocalizedVerticalCorridorLane(
      sourceNodeID: sourceNodeID,
      targetNodeID: targetNodeID,
      sourceScopeFrame: sourceFrame,
      targetScopeFrame: targetFrame,
      nodePositions: nodePositions
    ) {
      return localizedLane
    }
    return snappedLayoutDelta((sourceFrame.maxX + targetFrame.minX) / 2)
  }
  if targetFrame.maxX <= sourceFrame.minX {
    if let localizedLane = policyCanvasLocalizedVerticalCorridorLane(
      sourceNodeID: sourceNodeID,
      targetNodeID: targetNodeID,
      sourceScopeFrame: sourceFrame,
      targetScopeFrame: targetFrame,
      nodePositions: nodePositions
    ) {
      return localizedLane
    }
    return snappedLayoutDelta((targetFrame.maxX + sourceFrame.minX) / 2)
  }
  return nil
}

private func policyCanvasLocalizedVerticalCorridorLane(
  sourceNodeID: String,
  targetNodeID: String,
  sourceScopeFrame: CGRect,
  targetScopeFrame: CGRect,
  nodePositions: [String: CGPoint]
) -> CGFloat? {
  guard
    let sourcePosition = nodePositions[sourceNodeID],
    let targetPosition = nodePositions[targetNodeID]
  else {
    return nil
  }
  let sourceNodeFrame = CGRect(origin: sourcePosition, size: PolicyCanvasLayout.nodeSize)
  let targetNodeFrame = CGRect(origin: targetPosition, size: PolicyCanvasLayout.nodeSize)
  let verticalDelta = abs(targetNodeFrame.midY - sourceNodeFrame.midY)
  guard verticalDelta >= PolicyCanvasLayout.nodeSize.height else {
    return nil
  }

  if sourceScopeFrame.maxX <= targetScopeFrame.minX {
    let horizontalGap = max(0, targetNodeFrame.minX - sourceNodeFrame.maxX)
    guard horizontalGap > 0, verticalDelta >= horizontalGap * 2 else {
      return nil
    }
    let targetLocalX = max(
      sourceScopeFrame.maxX,
      targetNodeFrame.minX - (PolicyCanvasLayout.gridSize * 2)
    )
    return snappedLayoutDelta(min(targetLocalX, targetNodeFrame.minX))
  }

  if targetScopeFrame.maxX <= sourceScopeFrame.minX {
    let horizontalGap = max(0, sourceNodeFrame.minX - targetNodeFrame.maxX)
    guard horizontalGap > 0, verticalDelta >= horizontalGap * 2 else {
      return nil
    }
    let targetLocalX = min(
      sourceScopeFrame.minX,
      targetNodeFrame.maxX + (PolicyCanvasLayout.gridSize * 2)
    )
    return snappedLayoutDelta(max(targetLocalX, targetNodeFrame.maxX))
  }

  return nil
}

func policyCanvasLayoutGraph(
  nodes: [PolicyCanvasNode],
  groups: [PolicyCanvasGroup],
  edges: [PolicyCanvasEdge],
  mode: PolicyCanvasAutomaticLayoutMode
) -> PolicyCanvasLayoutGraph {
  let layoutNodes = nodes.enumerated().map { index, node in
    let anchor: PolicyCanvasLayoutAnchor?
    if mode.preservesManualAnchors, node.layoutSource == .manual {
      anchor = PolicyCanvasLayoutAnchor(position: node.position)
    } else {
      anchor = nil
    }
    return PolicyCanvasLayoutNode(
      id: node.id,
      groupID: node.groupID,
      originalIndex: index,
      currentPosition: node.position,
      anchor: anchor
    )
  }
  let groupMembership = Dictionary(
    uniqueKeysWithValues: groups.map { group in
      (group.id, nodes.filter { $0.groupID == group.id }.map(\.id))
    }
  )
  let layoutGroups = groups.enumerated().map { index, group in
    PolicyCanvasLayoutGroup(
      id: group.id,
      originalIndex: index,
      memberNodeIDs: groupMembership[group.id] ?? []
    )
  }
  let layoutEdges = edges.map { edge in
    PolicyCanvasLayoutEdge(
      id: edge.id,
      sourceNodeID: edge.source.nodeID,
      targetNodeID: edge.target.nodeID
    )
  }
  return PolicyCanvasLayoutGraph(
    nodes: layoutNodes,
    edges: layoutEdges,
    groups: layoutGroups
  )
}

extension PolicyCanvasLayeredLayoutEngine {
  fileprivate func normalizedGroups(for graph: PolicyCanvasLayoutGraph)
    -> [PolicyCanvasNormalizedLayoutGroup]
  {
    var groups = graph.groups.enumerated().map { index, group in
      PolicyCanvasNormalizedLayoutGroup(
        layoutID: group.id,
        actualGroupID: group.id,
        originalIndex: index,
        nodeIDs: uniqueNodeIDs(group.memberNodeIDs)
      )
    }
    var groupIndexByID = Dictionary(
      uniqueKeysWithValues: groups.enumerated().map { ($1.layoutID, $0) }
    )

    for node in graph.nodes {
      if let groupID = node.groupID {
        if let index = groupIndexByID[groupID] {
          if !groups[index].nodeIDs.contains(node.id) {
            groups[index].nodeIDs.append(node.id)
          }
          continue
        }
        groupIndexByID[groupID] = groups.count
        groups.append(
          PolicyCanvasNormalizedLayoutGroup(
            layoutID: groupID,
            actualGroupID: nil,
            originalIndex: groups.count,
            nodeIDs: [node.id]
          )
        )
        continue
      }
      groups.append(
        PolicyCanvasNormalizedLayoutGroup(
          layoutID: "__ungrouped__\(node.id)",
          actualGroupID: nil,
          originalIndex: groups.count,
          nodeIDs: [node.id]
        )
      )
    }

    return groups
  }

  fileprivate func unconstrainedLayeredLayout(
    graph: PolicyCanvasLayoutGraph,
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    layoutGroupIDByNodeID: [String: String],
    groupRanks: [String: Int],
    internalRanks: [String: Int],
    acyclicNodeEdges: [PolicyCanvasLayoutEdge],
    nodesByID _: [String: PolicyCanvasLayoutNode],
    configuration: PolicyCanvasLayoutConfiguration
  ) -> PolicyCanvasLayoutResult {
    let maxInternalRankByGroup = normalizedGroups.reduce(into: [:]) { partial, group in
      partial[group.layoutID] = group.nodeIDs.map { internalRanks[$0] ?? 0 }.max() ?? 0
    }
    let macroRanks = Set(groupRanks.values).sorted()
    let compositeBaseRankByMacroRank = compositeBaseRanks(
      macroRanks: macroRanks,
      normalizedGroups: normalizedGroups,
      groupRanks: groupRanks,
      maxInternalRankByGroup: maxInternalRankByGroup
    )
    let nodeRanks: [String: Int] = graph.nodes.reduce(into: [:]) { partial, node in
      guard let groupID = layoutGroupIDByNodeID[node.id] else {
        return
      }
      let macroRank = groupRanks[groupID] ?? 0
      let baseRank = compositeBaseRankByMacroRank[macroRank] ?? 0
      partial[node.id] = baseRank + (internalRanks[node.id] ?? 0)
    }
    let initialOrders = initialOrderHints(
      normalizedGroups: normalizedGroups,
      nodesByID: Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) }),
      edges: acyclicNodeEdges
    )
    let orderingGraph = policyCanvasAugmentedLayeredOrderingGraph(
      nodeIDs: graph.nodes.map(\.id),
      ranks: nodeRanks,
      edges: acyclicNodeEdges,
      initialOrders: initialOrders
    )
    let orderedLayers = policyCanvasReducedLayerOrders(
      graph: orderingGraph,
      maxPasses: configuration.sweepPassCount
    )
    let itemCenterY = policyCanvasLayeredItemCenterY(
      layers: orderedLayers,
      graph: orderingGraph,
      rowStep: configuration.rowStep
    )
    var orderHints: [String: Double] = [:]
    for layer in orderedLayers {
      let realNodeIDs = layer.compactMap { orderingGraph.itemsByID[$0]?.realNodeID }
      for (index, nodeID) in realNodeIDs.enumerated() {
        orderHints[nodeID] = Double(index)
      }
    }

    let groupOrder = orderedGroups(
      normalizedGroups: normalizedGroups,
      groupRanks: groupRanks,
      anchoredMinXByGroup: [:]
    )
    var nodePositions: [String: CGPoint] = [:]
    var groupFrames: [String: CGRect] = [:]
    var groupFramesByLayoutID: [String: CGRect] = [:]
    var autoPlacedNodeIDs: Set<String> = []
    var nextAutoGroupMinX: CGFloat = 0

    for group in groupOrder {
      let memberIDs = group.nodeIDs.filter { layoutGroupIDByNodeID[$0] == group.layoutID }
      guard !memberIDs.isEmpty else {
        continue
      }

      let placedNeighborCenterY: [String: CGFloat] = memberIDs.reduce(into: [:]) {
        partial, nodeID in
        let neighborCenters = graph.edges.compactMap { edge -> CGFloat? in
          if edge.targetNodeID == nodeID, let sourcePosition = nodePositions[edge.sourceNodeID] {
            return sourcePosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
          }
          if edge.sourceNodeID == nodeID, let targetPosition = nodePositions[edge.targetNodeID] {
            return targetPosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
          }
          return nil
        }
        guard !neighborCenters.isEmpty else {
          return
        }
        partial[nodeID] = neighborCenters.reduce(CGFloat.zero, +) / CGFloat(neighborCenters.count)
      }
      let orderedMembers = orderedFreeMembers(
        in: group,
        anchoredNodeIDs: [],
        internalRanks: internalRanks,
        orderHints: orderHints
      ).sorted { leftID, rightID in
        let leftRank = internalRanks[leftID] ?? 0
        let rightRank = internalRanks[rightID] ?? 0
        if leftRank != rightRank {
          return leftRank < rightRank
        }
        let leftPlacedCenterY = placedNeighborCenterY[leftID]
        let rightPlacedCenterY = placedNeighborCenterY[rightID]
        if let leftPlacedCenterY, let rightPlacedCenterY,
          abs(leftPlacedCenterY - rightPlacedCenterY) >= (PolicyCanvasLayout.gridSize / 2)
        {
          return leftPlacedCenterY < rightPlacedCenterY
        }
        let leftCenterY = itemCenterY[leftID] ?? 0
        let rightCenterY = itemCenterY[rightID] ?? 0
        if abs(leftCenterY - rightCenterY) >= (PolicyCanvasLayout.gridSize / 2) {
          return leftCenterY < rightCenterY
        }
        return (orderHints[leftID] ?? .zero) < (orderHints[rightID] ?? .zero)
      }
      let groupOrigin = CGPoint(x: nextAutoGroupMinX, y: 0)
      let xPlacement = placeFreeMembers(
        orderedMembers,
        internalRanks: internalRanks,
        groupOrigin: groupOrigin,
        reservedFrames: [],
        configuration: configuration,
        verticalHints: Dictionary(
          uniqueKeysWithValues: orderedMembers.map { nodeID in
            (nodeID, placedNeighborCenterY[nodeID] ?? itemCenterY[nodeID] ?? .zero)
          }
        )
      )
      let localBounds = orderedMembers.reduce(CGRect.null) { partial, nodeID in
        guard let position = xPlacement.positions[nodeID] else {
          return partial
        }
        return partial.union(CGRect(origin: position, size: PolicyCanvasLayout.nodeSize))
      }
      let targetCenters = orderedMembers.compactMap { itemCenterY[$0] }
      let targetCenterY: CGFloat
      if let minTargetCenterY = targetCenters.min(), let maxTargetCenterY = targetCenters.max() {
        targetCenterY = (minTargetCenterY + maxTargetCenterY) / 2
      } else {
        targetCenterY = 0
      }
      let localCenterY = localBounds.isNull ? 0 : localBounds.midY
      let yShift = snappedLayoutDelta(targetCenterY - localCenterY)
      let positions: [String: CGPoint] = orderedMembers.reduce(into: [:]) { partial, nodeID in
        guard let position = xPlacement.positions[nodeID] else {
          return
        }
        partial[nodeID] = snappedLayoutPoint(
          CGPoint(
            x: position.x,
            y: position.y + yShift
          )
        )
      }
      nodePositions.merge(positions) { _, new in new }
      autoPlacedNodeIDs.formUnion(orderedMembers)

      let memberBounds = memberIDs.reduce(CGRect.null) { partial, nodeID in
        guard let position = nodePositions[nodeID] else {
          return partial
        }
        return partial.union(CGRect(origin: position, size: PolicyCanvasLayout.nodeSize))
      }
      guard !memberBounds.isNull else {
        continue
      }

      let placementFrame: CGRect
      if let actualGroupID = group.actualGroupID {
        let frame = policyCanvasGroupFrame(containing: memberBounds)
        groupFrames[actualGroupID] = frame
        placementFrame = frame
      } else {
        placementFrame = memberBounds.integral
      }
      groupFramesByLayoutID[group.layoutID] = placementFrame
      nextAutoGroupMinX = max(
        nextAutoGroupMinX,
        placementFrame.maxX + configuration.interGroupSpacing
      )
    }

    let overallMinY =
      groupFrames.values.map(\.minY).min()
      ?? nodePositions.values.map(\.y).min()
      ?? 0
    if overallMinY < 0 {
      let yShift = -overallMinY
      nodePositions = nodePositions.mapValues { point in
        CGPoint(x: point.x, y: point.y + yShift)
      }
      groupFrames = groupFrames.mapValues { $0.offsetBy(dx: 0, dy: yShift) }
      groupFramesByLayoutID = groupFramesByLayoutID.mapValues { $0.offsetBy(dx: 0, dy: yShift) }
    }

    let metrics = policyCanvasMeasureLayoutMetrics(
      graph: graph,
      nodePositions: nodePositions,
      groupRanks: groupRanks,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID
    )
    let routingHints = policyCanvasLayoutRoutingHints(
      graph: graph,
      nodePositions: nodePositions,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID,
      groupFramesByLayoutID: groupFramesByLayoutID
    )
    return PolicyCanvasLayoutResult(
      nodePositions: nodePositions,
      groupFrames: groupFrames,
      autoPlacedNodeIDs: autoPlacedNodeIDs,
      metrics: metrics,
      routingHints: routingHints
    )
  }

  fileprivate func compositeBaseRanks(
    macroRanks: [Int],
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    groupRanks: [String: Int],
    maxInternalRankByGroup: [String: Int]
  ) -> [Int: Int] {
    var baseRanks: [Int: Int] = [:]
    var nextBaseRank = 0
    for macroRank in macroRanks {
      baseRanks[macroRank] = nextBaseRank
      let layerColumnCount = normalizedGroups.reduce(into: 1) { partial, group in
        guard groupRanks[group.layoutID] == macroRank else {
          return
        }
        partial = max(partial, (maxInternalRankByGroup[group.layoutID] ?? 0) + 1)
      }
      nextBaseRank += layerColumnCount
    }
    return baseRanks
  }

  fileprivate func layerBaseXByMacroRank(
    macroRanks: [Int],
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    groupRanks: [String: Int],
    maxInternalRankByGroup: [String: Int],
    configuration: PolicyCanvasLayoutConfiguration
  ) -> [Int: CGFloat] {
    var baseXByMacroRank: [Int: CGFloat] = [:]
    var nextBaseX: CGFloat = 0
    for macroRank in macroRanks {
      baseXByMacroRank[macroRank] = nextBaseX
      let layerWidth = normalizedGroups.reduce(into: CGFloat(PolicyCanvasLayout.nodeSize.width)) {
        partial, group in
        guard groupRanks[group.layoutID] == macroRank else {
          return
        }
        let contentWidth =
          CGFloat(maxInternalRankByGroup[group.layoutID] ?? 0) * configuration.columnStep
          + PolicyCanvasLayout.nodeSize.width
        let width: CGFloat
        if group.actualGroupID == nil {
          width = contentWidth
        } else {
          width = max(
            contentWidth + (PolicyCanvasLayout.groupHorizontalPadding * 2),
            PolicyCanvasLayout.minimumGroupSize.width
          )
        }
        partial = max(partial, width)
      }
      nextBaseX += layerWidth + configuration.interGroupSpacing
    }
    return baseXByMacroRank
  }

  fileprivate func anchoredMinXByGroup(
    nodesByID: [String: PolicyCanvasLayoutNode],
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup]
  ) -> [String: CGFloat] {
    Dictionary(
      uniqueKeysWithValues: normalizedGroups.compactMap { group in
        let anchoredMinX = group.nodeIDs.compactMap { nodeID in
          nodesByID[nodeID]?.anchor?.position.x
        }.min()
        guard let anchoredMinX else {
          return nil
        }
        return (group.layoutID, anchoredMinX)
      })
  }

  fileprivate func orderedGroups(
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    groupRanks: [String: Int],
    anchoredMinXByGroup: [String: CGFloat]
  ) -> [PolicyCanvasNormalizedLayoutGroup] {
    normalizedGroups.sorted { left, right in
      let leftRank = groupRanks[left.layoutID] ?? 0
      let rightRank = groupRanks[right.layoutID] ?? 0
      if leftRank != rightRank {
        return leftRank < rightRank
      }
      if mode.preservesManualAnchors,
        let leftAnchor = anchoredMinXByGroup[left.layoutID],
        let rightAnchor = anchoredMinXByGroup[right.layoutID],
        leftAnchor != rightAnchor
      {
        return leftAnchor < rightAnchor
      }
      return left.originalIndex < right.originalIndex
    }
  }

  fileprivate func groupRanks(
    for groups: [PolicyCanvasNormalizedLayoutGroup],
    edges: [PolicyCanvasLayoutEdge],
    layoutGroupIDByNodeID: [String: String]
  ) -> [String: Int] {
    longestPathRanks(
      ids: groups.map(\.layoutID),
      originalOrder: Dictionary(
        uniqueKeysWithValues: groups.map { ($0.layoutID, $0.originalIndex) }),
      successors: interGroupSuccessors(
        edges: edges,
        layoutGroupIDByNodeID: layoutGroupIDByNodeID
      )
    )
  }

  fileprivate func internalRanks(
    for groups: [PolicyCanvasNormalizedLayoutGroup],
    edges: [PolicyCanvasLayoutEdge],
    layoutGroupIDByNodeID: [String: String]
  ) -> [String: Int] {
    groups.reduce(into: [:]) { partial, group in
      let intraGroupEdges = edges.compactMap { edge -> (String, String)? in
        guard
          layoutGroupIDByNodeID[edge.sourceNodeID] == group.layoutID,
          layoutGroupIDByNodeID[edge.targetNodeID] == group.layoutID
        else {
          return nil
        }
        return (edge.sourceNodeID, edge.targetNodeID)
      }
      let ranks = longestPathRanks(
        ids: group.nodeIDs,
        originalOrder: Dictionary(
          uniqueKeysWithValues: group.nodeIDs.enumerated().map { ($1, $0) }),
        successors: intraGroupEdges.reduce(into: [:]) { successors, edge in
          successors[edge.0, default: []].insert(edge.1)
        }
      )
      partial.merge(ranks) { _, new in new }
    }
  }

  fileprivate func interGroupSuccessors(
    edges: [PolicyCanvasLayoutEdge],
    layoutGroupIDByNodeID: [String: String]
  ) -> [String: Set<String>] {
    edges.reduce(into: [:]) { partial, edge in
      guard
        let sourceGroupID = layoutGroupIDByNodeID[edge.sourceNodeID],
        let targetGroupID = layoutGroupIDByNodeID[edge.targetNodeID],
        sourceGroupID != targetGroupID
      else {
        return
      }
      partial[sourceGroupID, default: []].insert(targetGroupID)
    }
  }

  fileprivate func initialOrderHints(
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    nodesByID: [String: PolicyCanvasLayoutNode],
    edges: [PolicyCanvasLayoutEdge]
  ) -> [String: Double] {
    normalizedGroups.reduce(into: [:]) { partial, group in
      let orderedMembers = group.nodeIDs.sorted { leftID, rightID in
        guard let left = nodesByID[leftID], let right = nodesByID[rightID] else {
          return leftID < rightID
        }
        let leftSeed = initialOrderSeed(for: left, nodesByID: nodesByID, edges: edges)
        let rightSeed = initialOrderSeed(for: right, nodesByID: nodesByID, edges: edges)
        if leftSeed.priority != rightSeed.priority {
          return leftSeed.priority < rightSeed.priority
        }
        if leftSeed.y != rightSeed.y {
          return leftSeed.y < rightSeed.y
        }
        if leftSeed.x != rightSeed.x {
          return leftSeed.x < rightSeed.x
        }
        return left.originalIndex < right.originalIndex
      }
      for (index, nodeID) in orderedMembers.enumerated() {
        partial[nodeID] = Double(index)
      }
    }
  }

  fileprivate func initialOrderSeed(
    for node: PolicyCanvasLayoutNode,
    nodesByID: [String: PolicyCanvasLayoutNode],
    edges: [PolicyCanvasLayoutEdge]
  ) -> (priority: Int, y: CGFloat, x: CGFloat) {
    if let anchor = node.anchor {
      return (priority: 0, y: anchor.position.y, x: anchor.position.x)
    }
    if mode.seedsOrderHintsFromCurrentGeometry {
      let seedY = policyCanvasEdgeAwareSeedY(
        for: node.id,
        nodesByID: nodesByID,
        edges: edges
      ) ?? node.currentPosition.y
      return (
        priority: 1,
        y: seedY,
        x: node.currentPosition.x
      )
    }
    return (
      priority: 1,
      y: CGFloat(node.originalIndex),
      x: 0
    )
  }

  fileprivate func sweepOrderHints<G: Collection>(
    groups: G,
    graph: PolicyCanvasLayoutGraph,
    layoutGroupIDByNodeID: [String: String],
    internalRanks: [String: Int],
    preferIncomingNeighbors: Bool,
    orderHints: inout [String: Double]
  ) where G.Element == PolicyCanvasNormalizedLayoutGroup {
    for group in groups {
      let orderedNodeIDs = group.nodeIDs.sorted { leftID, rightID in
        let leftRank = internalRanks[leftID] ?? 0
        let rightRank = internalRanks[rightID] ?? 0
        if leftRank != rightRank {
          return leftRank < rightRank
        }
        let leftScore = barycenter(
          nodeID: leftID,
          graph: graph,
          groupID: group.layoutID,
          layoutGroupIDByNodeID: layoutGroupIDByNodeID,
          preferIncomingNeighbors: preferIncomingNeighbors,
          orderHints: orderHints
        )
        let rightScore = barycenter(
          nodeID: rightID,
          graph: graph,
          groupID: group.layoutID,
          layoutGroupIDByNodeID: layoutGroupIDByNodeID,
          preferIncomingNeighbors: preferIncomingNeighbors,
          orderHints: orderHints
        )
        if leftScore != rightScore {
          return leftScore < rightScore
        }
        return (orderHints[leftID] ?? .zero) < (orderHints[rightID] ?? .zero)
      }
      for (index, nodeID) in orderedNodeIDs.enumerated() {
        orderHints[nodeID] = Double(index)
      }
    }
  }

  fileprivate func barycenter(
    nodeID: String,
    graph: PolicyCanvasLayoutGraph,
    groupID: String,
    layoutGroupIDByNodeID: [String: String],
    preferIncomingNeighbors: Bool,
    orderHints: [String: Double]
  ) -> Double {
    let externalPreferredNeighbors = graph.edges.compactMap { edge -> Double? in
      if preferIncomingNeighbors,
        edge.targetNodeID == nodeID,
        layoutGroupIDByNodeID[edge.sourceNodeID] != groupID
      {
        return orderHints[edge.sourceNodeID]
      }
      if !preferIncomingNeighbors,
        edge.sourceNodeID == nodeID,
        layoutGroupIDByNodeID[edge.targetNodeID] != groupID
      {
        return orderHints[edge.targetNodeID]
      }
      return nil
    }
    let internalPreferredNeighbors = graph.edges.compactMap { edge -> Double? in
      if preferIncomingNeighbors,
        edge.targetNodeID == nodeID,
        layoutGroupIDByNodeID[edge.sourceNodeID] == groupID
      {
        return orderHints[edge.sourceNodeID]
      }
      if !preferIncomingNeighbors,
        edge.sourceNodeID == nodeID,
        layoutGroupIDByNodeID[edge.targetNodeID] == groupID
      {
        return orderHints[edge.targetNodeID]
      }
      return nil
    }
    let preferredNeighbors = externalPreferredNeighbors + internalPreferredNeighbors
    if !preferredNeighbors.isEmpty {
      return preferredNeighbors.reduce(0, +) / Double(preferredNeighbors.count)
    }
    return orderHints[nodeID] ?? .zero
  }

  fileprivate func orderedFreeMembers(
    in group: PolicyCanvasNormalizedLayoutGroup,
    anchoredNodeIDs: Set<String>,
    internalRanks: [String: Int],
    orderHints: [String: Double]
  ) -> [String] {
    group.nodeIDs
      .filter { !anchoredNodeIDs.contains($0) }
      .sorted { leftID, rightID in
        let leftRank = internalRanks[leftID] ?? 0
        let rightRank = internalRanks[rightID] ?? 0
        if leftRank != rightRank {
          return leftRank < rightRank
        }
        return (orderHints[leftID] ?? .zero) < (orderHints[rightID] ?? .zero)
      }
  }

  fileprivate func placeFreeMembers(
    _ nodeIDs: [String],
    internalRanks: [String: Int],
    groupOrigin: CGPoint,
    reservedFrames: [CGRect],
    configuration: PolicyCanvasLayoutConfiguration,
    verticalHints: [String: CGFloat] = [:]
  ) -> (positions: [String: CGPoint], frames: [CGRect]) {
    guard !nodeIDs.isEmpty else {
      return ([:], reservedFrames)
    }
    var positions: [String: CGPoint] = [:]
    var occupiedFrames = reservedFrames
    let ranks = Set(nodeIDs.map { internalRanks[$0] ?? 0 }).sorted()

    var startingColumn = 0
    for rank in ranks {
      let bucket = nodeIDs.filter { (internalRanks[$0] ?? 0) == rank }
      guard !bucket.isEmpty else {
        continue
      }
      let baseColumnCount = preferredColumnCount(
        memberCount: bucket.count,
        configuration: configuration
      )
      let hintValues = bucket.compactMap { verticalHints[$0] }
      let verticalHintSpread = (hintValues.max() ?? .zero) - (hintValues.min() ?? .zero)
      let columnCount =
        verticalHintSpread >= (configuration.rowStep * 3)
        ? max(1, baseColumnCount - 1)
        : baseColumnCount
      for (index, nodeID) in bucket.enumerated() {
        let subcolumn = index % columnCount
        var row = index / columnCount
        while true {
          let position = snappedLayoutPoint(
            CGPoint(
              x: groupOrigin.x + PolicyCanvasLayout.groupHorizontalPadding
                + (CGFloat(startingColumn + subcolumn) * configuration.columnStep),
              y: groupOrigin.y + PolicyCanvasLayout.groupVerticalPadding
                + (CGFloat(row) * configuration.rowStep)
            )
          )
          let frame = CGRect(origin: position, size: PolicyCanvasLayout.nodeSize)
          if occupiedFrames.allSatisfy({ !$0.intersects(frame) }) {
            positions[nodeID] = position
            occupiedFrames.append(frame)
            break
          }
          row += 1
        }
      }
      startingColumn += max(columnCount, 1)
    }

    return (positions, occupiedFrames)
  }

  fileprivate func preferredColumnCount(
    memberCount: Int,
    configuration: PolicyCanvasLayoutConfiguration
  ) -> Int {
    guard memberCount > 2 else {
      return 1
    }

    let aspectScale =
      (configuration.targetGroupAspectRatio * configuration.rowStep)
      / max(configuration.columnStep, 1)
    let rawColumns = sqrt(CGFloat(memberCount) * max(aspectScale, 0.5))
    return min(max(Int(rawColumns.rounded(.down)), 1), memberCount)
  }

  fileprivate func balanceGroupVerticalPositions(
    groups: [PolicyCanvasNormalizedLayoutGroup],
    graph: PolicyCanvasLayoutGraph,
    layoutGroupIDByNodeID: [String: String],
    anchoredGroupIDs: Set<String>,
    nodePositions: inout [String: CGPoint],
    groupFramesByLayoutID: inout [String: CGRect],
    groupFrames: inout [String: CGRect],
    configuration: PolicyCanvasLayoutConfiguration
  ) {
    guard groups.count > 1 else {
      return
    }
    let maxShiftPerPass = configuration.rowStep * 1.5
    let maximumBalancedGroupHeight =
      PolicyCanvasLayout.minimumGroupSize.height + configuration.rowStep
    for _ in 0..<3 {
      var movedAny = false
      for group in groups {
        guard
          !anchoredGroupIDs.contains(group.layoutID),
          let groupFrame = groupFramesByLayoutID[group.layoutID],
          groupFrame.height <= maximumBalancedGroupHeight,
          intraGroupEdgeCount(
            for: group.layoutID,
            graph: graph,
            layoutGroupIDByNodeID: layoutGroupIDByNodeID
          ) == 0
        else {
          continue
        }
        let endpointDeltas = graph.edges.compactMap { edge -> CGFloat? in
          guard
            let sourceGroupID = layoutGroupIDByNodeID[edge.sourceNodeID],
            let targetGroupID = layoutGroupIDByNodeID[edge.targetNodeID],
            sourceGroupID != targetGroupID,
            let sourcePosition = nodePositions[edge.sourceNodeID],
            let targetPosition = nodePositions[edge.targetNodeID]
          else {
            return nil
          }
          let sourceCenterY = sourcePosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
          let targetCenterY = targetPosition.y + (PolicyCanvasLayout.nodeSize.height / 2)
          if sourceGroupID == group.layoutID {
            return targetCenterY - sourceCenterY
          }
          if targetGroupID == group.layoutID {
            return sourceCenterY - targetCenterY
          }
          return nil
        }
        guard !endpointDeltas.isEmpty else {
          continue
        }
        let averageDelta = endpointDeltas.reduce(0, +) / CGFloat(endpointDeltas.count)
        var shiftY = snappedLayoutDelta(averageDelta * 0.5)
        shiftY = max(-maxShiftPerPass, min(maxShiftPerPass, shiftY))
        if groupFrame.minY + shiftY < 0 {
          shiftY = snappedLayoutDelta(-groupFrame.minY)
        }
        guard abs(shiftY) >= (PolicyCanvasLayout.gridSize / 2) else {
          continue
        }
        for nodeID in group.nodeIDs {
          guard var position = nodePositions[nodeID] else {
            continue
          }
          position.y += shiftY
          nodePositions[nodeID] = position
        }
        let nextFrame = groupFrame.offsetBy(dx: 0, dy: shiftY)
        groupFramesByLayoutID[group.layoutID] = nextFrame
        if let actualGroupID = group.actualGroupID {
          groupFrames[actualGroupID] = nextFrame
        }
        movedAny = true
      }
      if !movedAny {
        break
      }
    }
  }

  fileprivate func crossGroupOrderViolations(
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

  fileprivate func intraGroupEdgeCount(
    for groupID: String,
    graph: PolicyCanvasLayoutGraph,
    layoutGroupIDByNodeID: [String: String]
  ) -> Int {
    graph.edges.reduce(into: 0) { count, edge in
      guard
        layoutGroupIDByNodeID[edge.sourceNodeID] == groupID,
        layoutGroupIDByNodeID[edge.targetNodeID] == groupID
      else {
        return
      }
      count += 1
    }
  }
}

private func longestPathRanks(
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

private func uniqueNodeIDs(_ nodeIDs: [String]) -> [String] {
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
      targetNodeID: edge.sourceNodeID
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

func policyCanvasReducedLayerOrders(
  graph: PolicyCanvasLayeredOrderingGraph,
  maxPasses: Int
) -> [[String]] {
  var layers = graph.layers
  var bestLayers = layers
  var bestCrossings = policyCanvasLayeredOrderingCrossingCount(
    graph: graph,
    layers: layers
  )
  let passLimit = max(1, maxPasses)
  for _ in 0..<passLimit {
    var changed = false
    changed =
      policyCanvasSweepLayerOrders(layers: &layers, graph: graph, forward: true) || changed
    changed =
      policyCanvasSweepLayerOrders(layers: &layers, graph: graph, forward: false) || changed
    // Sugiyama barycenter + transpose is not monotonic in crossing count;
    // a later pass can replace a better intermediate layout. Keep the
    // minimum-crossing layout seen so the engine never ships worse output
    // than it produced mid-loop.
    let currentCrossings = policyCanvasLayeredOrderingCrossingCount(
      graph: graph,
      layers: layers
    )
    if currentCrossings < bestCrossings {
      bestCrossings = currentCrossings
      bestLayers = layers
    }
    if !changed {
      break
    }
  }
  return bestLayers
}

/// Count total cross-layer edge crossings for a layered ordering. Used by
/// `policyCanvasReducedLayerOrders` to track the best layout seen across
/// barycenter passes, and exposed for tests that pin the monotonic improvement
/// invariant.
func policyCanvasLayeredOrderingCrossingCount(
  graph: PolicyCanvasLayeredOrderingGraph,
  layers: [[String]]
) -> Int {
  guard layers.count > 1 else {
    return 0
  }
  var total = 0
  for index in 1..<layers.count {
    let upper = layers[index - 1]
    let lower = layers[index]
    let lowerOrder = Dictionary(
      uniqueKeysWithValues: lower.enumerated().map { ($1, $0) }
    )
    var edgeColumns: [(upper: Int, lower: Int)] = []
    for (upperPos, upperID) in upper.enumerated() {
      let successors = graph.outgoing[upperID] ?? []
      for successor in successors {
        guard let lowerPos = lowerOrder[successor] else {
          continue
        }
        edgeColumns.append((upperPos, lowerPos))
      }
    }
    // Sort edges by upper position; the crossing count is then the number of
    // inversions in the resulting `lower` sequence. Merge-sort gives this in
    // O(N log N) instead of the O(N^2) nested loop, which is the difference
    // between sub-second and seconds on dense graphs (60-wide × 5 layers).
    edgeColumns.sort { lhs, rhs in
      if lhs.upper != rhs.upper { return lhs.upper < rhs.upper }
      return lhs.lower < rhs.lower
    }
    var lowerSequence = edgeColumns.map { $0.lower }
    total += policyCanvasInversionCount(&lowerSequence)
  }
  return total
}

private func policyCanvasInversionCount(_ values: inout [Int]) -> Int {
  guard values.count > 1 else {
    return 0
  }
  var scratch = values
  return policyCanvasMergeCountInversions(&values, scratch: &scratch, lo: 0, hi: values.count)
}

private func policyCanvasMergeCountInversions(
  _ values: inout [Int],
  scratch: inout [Int],
  lo: Int,
  hi: Int
) -> Int {
  guard hi - lo > 1 else {
    return 0
  }
  let mid = (lo + hi) / 2
  var inversions = policyCanvasMergeCountInversions(
    &values,
    scratch: &scratch,
    lo: lo,
    hi: mid
  )
  inversions += policyCanvasMergeCountInversions(
    &values,
    scratch: &scratch,
    lo: mid,
    hi: hi
  )
  var i = lo
  var j = mid
  var k = lo
  while i < mid && j < hi {
    if values[i] <= values[j] {
      scratch[k] = values[i]
      i += 1
    } else {
      scratch[k] = values[j]
      inversions += mid - i
      j += 1
    }
    k += 1
  }
  while i < mid {
    scratch[k] = values[i]
    i += 1
    k += 1
  }
  while j < hi {
    scratch[k] = values[j]
    j += 1
    k += 1
  }
  for index in lo..<hi {
    values[index] = scratch[index]
  }
  return inversions
}

private func policyCanvasSweepLayerOrders(
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
      uniqueKeysWithValues: layers[movingRank].enumerated().map { ($1, $0) })
    let fixedOrder = Dictionary(
      uniqueKeysWithValues: layers[fixedRank].enumerated().map { ($1, $0) })
    var reorderedLayer = layers[movingRank].sorted { leftID, rightID in
      let leftScore = policyCanvasBarycenterScore(
        itemID: leftID,
        graph: graph,
        fixedOrder: fixedOrder,
        forward: forward,
        fallbackOrder: currentOrder[leftID] ?? 0
      )
      let rightScore = policyCanvasBarycenterScore(
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
    if reorderedLayer != layers[movingRank] {
      changed = true
    }
    policyCanvasTransposeLayer(
      movingLayer: &reorderedLayer,
      fixedLayer: layers[fixedRank],
      graph: graph,
      movingRank: movingRank,
      fixedRank: fixedRank,
      forward: forward
    )
    if reorderedLayer != layers[movingRank] {
      changed = true
    }
    layers[movingRank] = reorderedLayer
  }

  return changed
}

private func policyCanvasBarycenterScore(
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

private func policyCanvasTransposeLayer(
  movingLayer: inout [String],
  fixedLayer: [String],
  graph: PolicyCanvasLayeredOrderingGraph,
  movingRank: Int,
  fixedRank: Int,
  forward: Bool
) {
  guard movingLayer.count > 1 else {
    return
  }

  let fixedOrder = Dictionary(uniqueKeysWithValues: fixedLayer.enumerated().map { ($1, $0) })
  var neighborOrderCache: [String: [Int]] = [:]

  func fixedNeighborOrders(for itemID: String) -> [Int] {
    if let cached = neighborOrderCache[itemID] {
      return cached
    }
    let neighbors = (forward ? graph.incoming[itemID] : graph.outgoing[itemID]) ?? []
    let orders = neighbors.compactMap { neighborID -> Int? in
      guard
        graph.itemsByID[neighborID]?.rank == fixedRank,
        graph.itemsByID[itemID]?.rank == movingRank
      else {
        return nil
      }
      return fixedOrder[neighborID]
    }.sorted()
    neighborOrderCache[itemID] = orders
    return orders
  }

  func countOrdersBefore(_ order: Int, in sortedOrders: [Int]) -> Int {
    var lowerBound = sortedOrders.startIndex
    var upperBound = sortedOrders.endIndex
    while lowerBound < upperBound {
      let midpoint = lowerBound + ((upperBound - lowerBound) / 2)
      if sortedOrders[midpoint] < order {
        lowerBound = midpoint + 1
      } else {
        upperBound = midpoint
      }
    }
    return lowerBound
  }

  func crossingCount(leadingOrders: [Int], trailingOrders: [Int]) -> Int {
    var crossings = 0
    for leadingOrder in leadingOrders {
      crossings += countOrdersBefore(leadingOrder, in: trailingOrders)
    }
    return crossings
  }

  var improved = true
  while improved {
    improved = false
    for index in 0..<(movingLayer.count - 1) {
      let leftID = movingLayer[index]
      let rightID = movingLayer[index + 1]
      let leftOrders = fixedNeighborOrders(for: leftID)
      let rightOrders = fixedNeighborOrders(for: rightID)
      let existingCrossings = crossingCount(
        leadingOrders: leftOrders,
        trailingOrders: rightOrders
      )
      let swappedCrossings = crossingCount(
        leadingOrders: rightOrders,
        trailingOrders: leftOrders
      )
      if swappedCrossings < existingCrossings {
        movingLayer.swapAt(index, index + 1)
        improved = true
      }
    }
  }
}

func policyCanvasLayeredItemCenterY(
  layers: [[String]],
  graph: PolicyCanvasLayeredOrderingGraph,
  rowStep: CGFloat
) -> [String: CGFloat] {
  var centers: [String: CGFloat] = [:]
  for layer in layers {
    let initialCenters = policyCanvasCenteredLayerCenters(count: layer.count, rowStep: rowStep)
    for (itemID, centerY) in zip(layer, initialCenters) {
      centers[itemID] = centerY
    }
  }

  for _ in 0..<8 {
    var changed = false
    var nextCenters = centers
    for layer in layers {
      let targetCenters = layer.map { itemID -> CGFloat in
        let neighborCenters = ((graph.incoming[itemID] ?? []) + (graph.outgoing[itemID] ?? []))
          .compactMap { centers[$0] }
        guard !neighborCenters.isEmpty else {
          return centers[itemID] ?? 0
        }
        return neighborCenters.reduce(0, +) / CGFloat(neighborCenters.count)
      }
      let compactedCenters = policyCanvasCompactedLayerCenters(
        targetCenters: targetCenters,
        rowStep: rowStep
      )
      for (itemID, centerY) in zip(layer, compactedCenters) {
        if abs((nextCenters[itemID] ?? 0) - centerY) >= (PolicyCanvasLayout.gridSize / 2) {
          changed = true
        }
        nextCenters[itemID] = centerY
      }
    }
    centers = nextCenters
    if !changed {
      break
    }
  }
  return centers
}

private func policyCanvasCenteredLayerCenters(
  count: Int,
  rowStep: CGFloat
) -> [CGFloat] {
  guard count > 0 else {
    return []
  }
  let totalHeight = CGFloat(max(0, count - 1)) * rowStep
  return (0..<count).map { index in
    (CGFloat(index) * rowStep) - (totalHeight / 2)
  }
}

private func policyCanvasCompactedLayerCenters(
  targetCenters: [CGFloat],
  rowStep: CGFloat
) -> [CGFloat] {
  guard !targetCenters.isEmpty else {
    return []
  }
  var compactedCenters = targetCenters
  for index in 1..<compactedCenters.count {
    compactedCenters[index] = max(
      targetCenters[index],
      compactedCenters[index - 1] + rowStep
    )
  }
  let targetMidpoint = (targetCenters.first! + targetCenters.last!) / 2
  let compactedMidpoint = (compactedCenters.first! + compactedCenters.last!) / 2
  let shift = targetMidpoint - compactedMidpoint
  return compactedCenters.map { $0 + shift }
}

private func snappedLayoutPoint(_ point: CGPoint) -> CGPoint {
  CGPoint(
    x: (point.x / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize,
    y: (point.y / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize
  )
}

private func snappedLayoutDelta(_ value: CGFloat) -> CGFloat {
  (value / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize
}
