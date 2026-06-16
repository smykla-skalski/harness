import SwiftUI

public struct PolicyCanvasRouteEndpointSlot: Hashable, Sendable {
  public let index: Int
  public let count: Int

  public static let single = Self(index: 0, count: 1)

  public init(index: Int, count: Int) {
    self.index = index
    self.count = count
  }
}

public struct PolicyCanvasRouteEndpointSlots: Hashable, Sendable {
  public let source: PolicyCanvasRouteEndpointSlot
  public let target: PolicyCanvasRouteEndpointSlot

  public init(source: PolicyCanvasRouteEndpointSlot, target: PolicyCanvasRouteEndpointSlot) {
    self.source = source
    self.target = target
  }
}

public func policyCanvasRouteEndpointSlots(
  edges: [PolicyCanvasEdge]
) -> [String: PolicyCanvasRouteEndpointSlots] {
  policyCanvasRouteEndpointSlots(
    edges: edges,
    sourceSortKey: policyCanvasSourceEndpointSlotSortKey,
    targetSortKey: policyCanvasTargetEndpointSlotSortKey
  )
}

func policyCanvasRouteEndpointSlots(
  edges: [PolicyCanvasEdge],
  sourceSortKey: (PolicyCanvasEdge) -> String,
  targetSortKey: (PolicyCanvasEdge) -> String
) -> [String: PolicyCanvasRouteEndpointSlots] {
  let sourceSlots = policyCanvasEndpointSlots(
    edges: edges,
    endpoint: \.source,
    sortKey: sourceSortKey
  )
  let targetSlots = policyCanvasEndpointSlots(
    edges: edges,
    endpoint: \.target,
    sortKey: targetSortKey
  )
  return Dictionary(
    uniqueKeysWithValues: edges.map { edge in
      (
        edge.id,
        PolicyCanvasRouteEndpointSlots(
          source: sourceSlots[edge.id, default: .single],
          target: targetSlots[edge.id, default: .single]
        )
      )
    })
}

private func policyCanvasEndpointSlots(
  edges: [PolicyCanvasEdge],
  endpoint: KeyPath<PolicyCanvasEdge, PolicyCanvasPortEndpoint>,
  sortKey: (PolicyCanvasEdge) -> String
) -> [String: PolicyCanvasRouteEndpointSlot] {
  let groups = Dictionary(grouping: edges) { edge in
    policyCanvasRouteEndpointKey(edge[keyPath: endpoint])
  }
  var slots: [String: PolicyCanvasRouteEndpointSlot] = [:]
  for groupEdges in groups.values where groupEdges.count > 1 {
    let sortedEdges = groupEdges.sorted { left, right in
      let leftKey = sortKey(left)
      let rightKey = sortKey(right)
      if leftKey != rightKey {
        return leftKey < rightKey
      }
      return left.id < right.id
    }
    for (index, edge) in sortedEdges.enumerated() {
      slots[edge.id] = PolicyCanvasRouteEndpointSlot(index: index, count: sortedEdges.count)
    }
  }
  return slots
}

private func policyCanvasSourceEndpointSlotSortKey(_ edge: PolicyCanvasEdge) -> String {
  [
    edge.target.nodeID,
    edge.target.portID,
    edge.label,
    edge.id,
  ]
  .joined(separator: "|")
}

private func policyCanvasTargetEndpointSlotSortKey(_ edge: PolicyCanvasEdge) -> String {
  [
    edge.source.nodeID,
    edge.source.portID,
    edge.label,
    edge.id,
  ]
  .joined(separator: "|")
}

private func policyCanvasRouteEndpointKey(
  _ endpoint: PolicyCanvasPortEndpoint
) -> PolicyCanvasPortEndpoint {
  PolicyCanvasPortEndpoint(
    nodeID: endpoint.nodeID,
    portID: endpoint.portID,
    kind: endpoint.kind
  )
}

public func policyCanvasShiftedRouteAnchor(
  _ point: CGPoint,
  side: PolicyCanvasPortSide,
  frame: CGRect,
  spacing: CGFloat,
  terminalSlot: PolicyCanvasRouteEndpointSlot
) -> CGPoint {
  let offset = policyCanvasRouteEndpointSlotOffset(
    terminalSlot,
    spacing: spacing
  )
  guard abs(offset) > 0.001 else {
    return point
  }
  let inset = (PolicyCanvasLayout.portDiameter / 2) + 4
  switch side {
  case .leading, .trailing:
    let coordinate = point.y - frame.minY
    let overflow = policyCanvasRouteEndpointSlotOverflow(
      terminalSlot,
      spacing: spacing,
      coordinate: coordinate,
      extent: frame.height
    )
    return CGPoint(
      x: point.x,
      y: min(
        max(point.y + offset, frame.minY + inset - overflow),
        frame.maxY - inset + overflow
      )
    )
  case .top, .bottom:
    let coordinate = point.x - frame.minX
    let overflow = policyCanvasRouteEndpointSlotOverflow(
      terminalSlot,
      spacing: spacing,
      coordinate: coordinate,
      extent: frame.width
    )
    return CGPoint(
      x: min(
        max(point.x + offset, frame.minX + inset - overflow),
        frame.maxX - inset + overflow
      ),
      y: point.y
    )
  }
}

private func policyCanvasRouteEndpointSlotOffset(
  _ slot: PolicyCanvasRouteEndpointSlot,
  spacing: CGFloat
) -> CGFloat {
  guard slot.count > 1 else {
    return 0
  }
  let centeredIndex = CGFloat(slot.index) - (CGFloat(slot.count - 1) / 2)
  return centeredIndex * spacing
}

private func policyCanvasRouteEndpointSlotOverflow(
  _ slot: PolicyCanvasRouteEndpointSlot,
  spacing: CGFloat,
  coordinate: CGFloat,
  extent: CGFloat
) -> CGFloat {
  let inset = PolicyCanvasLayout.portDiameter / 2 + 4
  let halfSpan = (CGFloat(slot.count - 1) * spacing) / 2
  let before = max(0, coordinate - inset)
  let after = max(0, extent - inset - coordinate)
  return max(0, halfSpan - before, halfSpan - after)
}
