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
  let sourceSlots = policyCanvasEndpointSlots(
    edges: edges,
    endpoint: \.source,
    sortKey: policyCanvasSourceEndpointSlotSortKey
  )
  let targetSlots = policyCanvasEndpointSlots(
    edges: edges,
    endpoint: \.target,
    sortKey: policyCanvasTargetEndpointSlotSortKey
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
    spacing: spacing,
    point: point,
    side: side,
    frame: frame
  )
  guard abs(offset) > 0.001 else {
    return point
  }
  let inset = (PolicyCanvasLayout.portDiameter / 2) + 4
  switch side {
  case .leading, .trailing:
    let overflow = policyCanvasRouteEndpointSlotOverflow(
      terminalSlot,
      spacing: spacing,
      extent: PolicyCanvasLayout.nodeSize.height
    )
    return CGPoint(
      x: point.x,
      y: min(
        max(point.y + offset, frame.minY + inset - overflow),
        frame.maxY - inset + overflow
      )
    )
  case .top, .bottom:
    let overflow = policyCanvasRouteEndpointSlotOverflow(
      terminalSlot,
      spacing: spacing,
      extent: PolicyCanvasLayout.nodeSize.width
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
  spacing: CGFloat,
  point: CGPoint,
  side: PolicyCanvasPortSide,
  frame: CGRect
) -> CGFloat {
  guard slot.count > 1 else {
    return 0
  }
  let coordinate: CGFloat
  let midpoint: CGFloat
  switch side {
  case .leading, .trailing:
    coordinate = point.y
    midpoint = frame.midY
  case .top, .bottom:
    coordinate = point.x
    midpoint = frame.midX
  }
  let direction: CGFloat = coordinate < midpoint ? -1 : 1
  return CGFloat(slot.index) * spacing * direction
}

private func policyCanvasRouteEndpointSlotOverflow(
  _ slot: PolicyCanvasRouteEndpointSlot,
  spacing: CGFloat,
  extent: CGFloat
) -> CGFloat {
  max(0, CGFloat(slot.count - 1) * spacing - (extent / 2))
}
