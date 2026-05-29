import SwiftUI

struct PolicyCanvasPortMarkerEntry: Comparable {
  let key: PolicyCanvasRouteTerminalKey
  let endpoint: PolicyCanvasPortEndpoint
  let preferredSide: PolicyCanvasPortSide
  let collapsedTerminalGroup: String?
  let sortKey: String

  var endpointKey: PolicyCanvasPortEndpoint {
    policyCanvasCanonicalPortEndpoint(endpoint)
  }

  var nodeKey: PolicyCanvasPortMarkerNodeKey {
    PolicyCanvasPortMarkerNodeKey(nodeID: endpoint.nodeID, kind: endpoint.kind)
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.sortKey == rhs.sortKey ? lhs.key.edgeID < rhs.key.edgeID : lhs.sortKey < rhs.sortKey
  }
}

struct PolicyCanvasPortMarkerAssignmentUnit: Comparable {
  let id: String
  let entries: [PolicyCanvasPortMarkerEntry]
  let preferredSide: PolicyCanvasPortSide
  let sortKey: String

  var endpointKey: PolicyCanvasPortEndpoint {
    entries[0].endpointKey
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.sortKey == rhs.sortKey ? lhs.id < rhs.id : lhs.sortKey < rhs.sortKey
  }
}

func policyCanvasPortMarkerAssignmentUnits(
  _ entries: [PolicyCanvasPortMarkerEntry],
  sides: [PolicyCanvasPortSide]
) -> [PolicyCanvasPortMarkerAssignmentUnit] {
  Dictionary(grouping: entries) { entry in
    entry.collapsedTerminalGroup ?? "\(entry.key.edgeID)|\(String(describing: entry.key.role))"
  }
  .map { id, groupedEntries in
    let sortedEntries = groupedEntries.sorted()
    let preferredCounts = Dictionary(grouping: sortedEntries) { entry in
      sides.contains(entry.preferredSide) ? entry.preferredSide : sides[0]
    }
    let preferredSide = preferredCounts.max { left, right in
      left.value.count < right.value.count
    }?.key ?? (sides.contains(sortedEntries[0].preferredSide) ? sortedEntries[0].preferredSide : sides[0])
    return PolicyCanvasPortMarkerAssignmentUnit(
      id: id,
      entries: sortedEntries,
      preferredSide: preferredSide,
      sortKey: sortedEntries[0].sortKey
    )
  }
  .sorted()
}

struct PolicyCanvasPortMarkerNodeKey: Hashable {
  let nodeID: String
  let kind: PolicyCanvasPortKind
}

func policyCanvasPortMarkerSortKey(
  edge: PolicyCanvasEdge,
  role: PolicyCanvasRouteEndpointRole
) -> String {
  switch role {
  case .source:
    [edge.target.nodeID, edge.target.portID, edge.label, edge.id].joined(separator: "|")
  case .target:
    [edge.source.nodeID, edge.source.portID, edge.label, edge.id].joined(separator: "|")
  }
}

func policyCanvasPortMarkerCoordinates(
  count: Int,
  base: CGFloat,
  spacing: CGFloat,
  extent: CGFloat,
  inset: CGFloat
) -> [CGFloat] {
  guard count > 1 else {
    return [min(max(base, inset), extent - inset)]
  }
  let available = max(0, extent - (inset * 2))
  let step = min(spacing, available / CGFloat(count - 1))
  let span = step * CGFloat(count - 1)
  let start = min(max(base - (span / 2), inset), extent - inset - span)
  return (0..<count).map { start + (CGFloat($0) * step) }
}

func policyCanvasSideExtent(side: PolicyCanvasPortSide) -> CGFloat {
  switch side {
  case .leading, .trailing:
    PolicyCanvasLayout.nodeSize.height
  case .top, .bottom:
    PolicyCanvasLayout.nodeSize.width
  }
}

func policyCanvasLocalAxisCoordinate(
  _ point: CGPoint,
  side: PolicyCanvasPortSide,
  frame: CGRect
) -> CGFloat {
  switch side {
  case .leading, .trailing:
    point.y - frame.minY
  case .top, .bottom:
    point.x - frame.minX
  }
}

func policyCanvasSortedUniquePortMarkerOffsets(_ offsets: [CGFloat]) -> [CGFloat] {
  offsets.sorted().reduce(into: [CGFloat]()) { unique, offset in
    if unique.last.map({ abs($0 - offset) > 0.001 }) ?? true {
      unique.append(offset)
    }
  }
}
