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
    case .explicitReflow:
      false
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

struct PolicyCanvasLayoutResult: Sendable {
  let nodePositions: [String: CGPoint]
  let groupFrames: [String: CGRect]
  let autoPlacedNodeIDs: Set<String>
  let metrics: PolicyCanvasLayoutMetrics
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
    sweepPassCount: 2
  )
}

protocol PolicyCanvasLayoutEngine {
  func layout(
    graph: PolicyCanvasLayoutGraph,
    configuration: PolicyCanvasLayoutConfiguration
  ) -> PolicyCanvasLayoutResult?
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
    let anchoredNodeIDs = Set(graph.nodes.compactMap { node in
      node.anchor == nil ? nil : node.id
    })
    let anchoredMinXByGroup = anchoredMinXByGroup(
      nodesByID: nodesByID,
      normalizedGroups: normalizedGroups
    )
    let groupRanks = groupRanks(
      for: normalizedGroups,
      edges: graph.edges,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID
    )
    let internalRanks = internalRanks(
      for: normalizedGroups,
      edges: graph.edges,
      layoutGroupIDByNodeID: layoutGroupIDByNodeID
    )
    let groupOrder = orderedGroups(
      normalizedGroups: normalizedGroups,
      groupRanks: groupRanks,
      anchoredMinXByGroup: anchoredMinXByGroup
    )
    var orderHints = initialOrderHints(
      normalizedGroups: normalizedGroups,
      nodesByID: nodesByID
    )
    for _ in 0..<configuration.sweepPassCount {
      sweepOrderHints(
        groups: groupOrder,
        graph: graph,
        layoutGroupIDByNodeID: layoutGroupIDByNodeID,
        internalRanks: internalRanks,
        preferIncomingNeighbors: true,
        orderHints: &orderHints
      )
      sweepOrderHints(
        groups: groupOrder.reversed(),
        graph: graph,
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
    return PolicyCanvasLayoutResult(
      nodePositions: nodePositions,
      groupFrames: groupFrames,
      autoPlacedNodeIDs: autoPlacedNodeIDs,
      metrics: metrics
    )
  }
}

private struct PolicyCanvasNormalizedLayoutGroup {
  let layoutID: String
  let actualGroupID: String?
  let originalIndex: Int
  var nodeIDs: [String]
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

private extension PolicyCanvasLayeredLayoutEngine {
  func normalizedGroups(for graph: PolicyCanvasLayoutGraph) -> [PolicyCanvasNormalizedLayoutGroup] {
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

  func anchoredMinXByGroup(
    nodesByID: [String: PolicyCanvasLayoutNode],
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup]
  ) -> [String: CGFloat] {
    Dictionary(uniqueKeysWithValues: normalizedGroups.compactMap { group in
      let anchoredMinX = group.nodeIDs.compactMap { nodeID in
        nodesByID[nodeID]?.anchor?.position.x
      }.min()
      guard let anchoredMinX else {
        return nil
      }
      return (group.layoutID, anchoredMinX)
    })
  }

  func orderedGroups(
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

  func groupRanks(
    for groups: [PolicyCanvasNormalizedLayoutGroup],
    edges: [PolicyCanvasLayoutEdge],
    layoutGroupIDByNodeID: [String: String]
  ) -> [String: Int] {
    longestPathRanks(
      ids: groups.map(\.layoutID),
      originalOrder: Dictionary(uniqueKeysWithValues: groups.map { ($0.layoutID, $0.originalIndex) }),
      successors: interGroupSuccessors(
        edges: edges,
        layoutGroupIDByNodeID: layoutGroupIDByNodeID
      )
    )
  }

  func internalRanks(
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
        originalOrder: Dictionary(uniqueKeysWithValues: group.nodeIDs.enumerated().map { ($1, $0) }),
        successors: intraGroupEdges.reduce(into: [:]) { successors, edge in
          successors[edge.0, default: []].insert(edge.1)
        }
      )
      partial.merge(ranks) { _, new in new }
    }
  }

  func interGroupSuccessors(
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

  func initialOrderHints(
    normalizedGroups: [PolicyCanvasNormalizedLayoutGroup],
    nodesByID: [String: PolicyCanvasLayoutNode]
  ) -> [String: Double] {
    normalizedGroups.reduce(into: [:]) { partial, group in
      let orderedMembers = group.nodeIDs.sorted { leftID, rightID in
        guard let left = nodesByID[leftID], let right = nodesByID[rightID] else {
          return leftID < rightID
        }
        let leftSeed = initialOrderSeed(for: left)
        let rightSeed = initialOrderSeed(for: right)
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

  func initialOrderSeed(
    for node: PolicyCanvasLayoutNode
  ) -> (priority: Int, y: CGFloat, x: CGFloat) {
    if let anchor = node.anchor {
      return (priority: 0, y: anchor.position.y, x: anchor.position.x)
    }
    if mode.seedsOrderHintsFromCurrentGeometry {
      return (
        priority: 1,
        y: node.currentPosition.y,
        x: node.currentPosition.x
      )
    }
    return (
      priority: 1,
      y: CGFloat(node.originalIndex),
      x: 0
    )
  }

  func sweepOrderHints<G: Collection>(
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

  func barycenter(
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

  func orderedFreeMembers(
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

  func placeFreeMembers(
    _ nodeIDs: [String],
    internalRanks: [String: Int],
    groupOrigin: CGPoint,
    reservedFrames: [CGRect],
    configuration: PolicyCanvasLayoutConfiguration
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
      let columnCount = preferredColumnCount(
        memberCount: bucket.count,
        configuration: configuration
      )
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

  func preferredColumnCount(
    memberCount: Int,
    configuration: PolicyCanvasLayoutConfiguration
  ) -> Int {
    guard memberCount > 1 else {
      return 1
    }
    let estimate = sqrt(
      (Double(memberCount) * Double(configuration.rowStep))
        / (Double(configuration.columnStep) * Double(configuration.targetGroupAspectRatio))
    )
    return max(1, min(memberCount, Int(estimate.rounded(.up))))
  }

  func balanceGroupVerticalPositions(
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
    let maximumBalancedGroupHeight = PolicyCanvasLayout.minimumGroupSize.height + configuration.rowStep
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

  func crossGroupOrderViolations(
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

  func intraGroupEdgeCount(
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

  let orderedIDs = ids.sorted { (originalOrder[$0] ?? .max) < (originalOrder[$1] ?? .max) }
  var queue = orderedIDs.filter { (indegree[$0] ?? 0) == 0 }
  var ranks = ids.reduce(into: [:]) { partial, id in
    partial[id] = 0
  }
  var visited: Set<String> = []

  while let currentID = queue.first {
    queue.removeFirst()
    visited.insert(currentID)
    let currentRank = ranks[currentID] ?? 0
    let nextIDs = (successors[currentID] ?? []).sorted {
      (originalOrder[$0] ?? .max) < (originalOrder[$1] ?? .max)
    }
    for nextID in nextIDs {
      ranks[nextID] = max(ranks[nextID] ?? 0, currentRank + 1)
      indegree[nextID, default: 0] -= 1
      if indegree[nextID] == 0 {
        queue.append(nextID)
      }
    }
    queue.sort { (originalOrder[$0] ?? .max) < (originalOrder[$1] ?? .max) }
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

private func snappedLayoutPoint(_ point: CGPoint) -> CGPoint {
  CGPoint(
    x: (point.x / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize,
    y: (point.y / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize
  )
}

private func snappedLayoutDelta(_ value: CGFloat) -> CGFloat {
  (value / PolicyCanvasLayout.gridSize).rounded() * PolicyCanvasLayout.gridSize
}
