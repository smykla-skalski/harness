import SwiftUI

enum PolicyCanvasRouteEndpointRole: Hashable, Sendable {
  case source
  case target
}

struct PolicyCanvasRouteTerminalKey: Hashable, Sendable {
  let edgeID: String
  let role: PolicyCanvasRouteEndpointRole
}

struct PolicyCanvasPortTerminal: Equatable, Sendable {
  let side: PolicyCanvasPortSide
  let axisOffset: CGFloat
}

struct PolicyCanvasPortMarker: Identifiable, Hashable, Sendable {
  let id: String
  let axisOffset: CGFloat
  let allowsInteraction: Bool
}

struct PolicyCanvasPortMarkerLayout: Equatable, Sendable {
  private let terminalsByKey: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal]
  private let offsetsByEndpoint: [PolicyCanvasPortEndpoint: [PolicyCanvasPortSide: [CGFloat]]]

  static let empty = Self(terminalsByKey: [:], endpointsByKey: [:])

  init(
    terminalsByKey: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal],
    endpointsByKey: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortEndpoint]
  ) {
    self.terminalsByKey = terminalsByKey
    var offsets: [PolicyCanvasPortEndpoint: [PolicyCanvasPortSide: [CGFloat]]] = [:]
    for (key, terminal) in terminalsByKey {
      guard let endpoint = endpointsByKey[key] else {
        continue
      }
      let endpointKey = policyCanvasCanonicalPortEndpoint(endpoint)
      offsets[endpointKey, default: [:]][terminal.side, default: []].append(terminal.axisOffset)
    }
    offsetsByEndpoint = offsets.mapValues { sideMap in
      sideMap.mapValues(policyCanvasSortedUniquePortMarkerOffsets)
    }
  }

  func terminal(
    edgeID: String,
    role: PolicyCanvasRouteEndpointRole
  ) -> PolicyCanvasPortTerminal? {
    terminalsByKey[PolicyCanvasRouteTerminalKey(edgeID: edgeID, role: role)]
  }

  func markers(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    isVisible: Bool
  ) -> [PolicyCanvasPortMarker] {
    guard isVisible else {
      return []
    }
    let offsets = offsetsByEndpoint[policyCanvasCanonicalPortEndpoint(endpoint)]?[side] ?? [0]
    let primaryIndex =
      offsets.indices.min { left, right in
        abs(offsets[left]) < abs(offsets[right])
      } ?? offsets.startIndex
    return offsets.enumerated().map { index, offset in
      PolicyCanvasPortMarker(
        id: "\(side.rawValue)-\(Int((offset * 1_000).rounded()))",
        axisOffset: offset,
        allowsInteraction: index == primaryIndex
      )
    }
  }
}

func policyCanvasCanonicalPortEndpoint(
  _ endpoint: PolicyCanvasPortEndpoint
) -> PolicyCanvasPortEndpoint {
  PolicyCanvasPortEndpoint(
    nodeID: endpoint.nodeID,
    portID: endpoint.portID,
    kind: endpoint.kind
  )
}

func policyCanvasRoutablePortSides(for kind: PolicyCanvasPortKind) -> [PolicyCanvasPortSide] {
  switch kind {
  case .input:
    [.leading, .top]
  case .output:
    [.trailing, .bottom]
  }
}

func policyCanvasShiftedRouteAnchor(
  _ point: CGPoint,
  side: PolicyCanvasPortSide,
  terminal: PolicyCanvasPortTerminal
) -> CGPoint {
  switch side {
  case .leading, .trailing:
    CGPoint(x: point.x, y: point.y + terminal.axisOffset)
  case .top, .bottom:
    CGPoint(x: point.x + terminal.axisOffset, y: point.y)
  }
}

extension PolicyCanvasPreparedRouteInput {
  func portMarkerLayout(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasPortMarkerLayout {
    let entries = portMarkerEntries(routes: routes)
    let groups = Dictionary(grouping: entries) { $0.nodeKey }
    var terminals: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal] = [:]
    for groupEntries in groups.values {
      assignPortMarkerTerminals(
        entries: groupEntries.sorted(),
        nodeIndex: nodeIndex,
        terminals: &terminals
      )
    }
    return PolicyCanvasPortMarkerLayout(
      terminalsByKey: terminals,
      endpointsByKey: Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.endpoint) })
    )
  }

  private func portMarkerEntries(
    routes: [String: PolicyCanvasEdgeRoute]
  ) -> [PolicyCanvasPortMarkerEntry] {
    edges.flatMap { edge -> [PolicyCanvasPortMarkerEntry] in
      guard let route = routes[edge.id] else {
        return []
      }
      return [
        PolicyCanvasPortMarkerEntry(
          key: PolicyCanvasRouteTerminalKey(edgeID: edge.id, role: .source),
          endpoint: edge.source,
          preferredSide: policyCanvasRouteSourceSide(route)
            ?? policyCanvasResolvedPortSide(for: edge.source),
          sortKey: policyCanvasPortMarkerSortKey(edge: edge, role: .source)
        ),
        PolicyCanvasPortMarkerEntry(
          key: PolicyCanvasRouteTerminalKey(edgeID: edge.id, role: .target),
          endpoint: edge.target,
          preferredSide: policyCanvasRouteTargetSide(route)
            ?? policyCanvasResolvedPortSide(for: edge.target),
          sortKey: policyCanvasPortMarkerSortKey(edge: edge, role: .target)
        ),
      ]
    }
  }

  private func assignPortMarkerTerminals(
    entries: [PolicyCanvasPortMarkerEntry],
    nodeIndex: [String: PolicyCanvasRouteNode],
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal]
  ) {
    guard let endpoint = entries.first?.endpoint else {
      return
    }
    let sides = policyCanvasRoutablePortSides(for: endpoint.kind)
    var entriesBySide = Dictionary(
      uniqueKeysWithValues: sides.map { ($0, [PolicyCanvasPortMarkerEntry]()) }
    )
    let capacities = Dictionary(
      uniqueKeysWithValues: sides.map { side in
        (side, portMarkerCapacity(for: endpoint, side: side, nodeIndex: nodeIndex))
      })
    for entry in entries {
      let preferred = sides.contains(entry.preferredSide) ? entry.preferredSide : sides[0]
      let side = firstAvailableSide(
        preferred: preferred,
        sides: sides,
        capacities: capacities,
        counts: entriesBySide
      )
      entriesBySide[side, default: []].append(entry)
    }
    for side in sides {
      assignPortMarkerOffsets(
        entries: entriesBySide[side, default: []],
        side: side,
        nodeIndex: nodeIndex,
        terminals: &terminals
      )
    }
  }

  private func firstAvailableSide(
    preferred: PolicyCanvasPortSide,
    sides: [PolicyCanvasPortSide],
    capacities: [PolicyCanvasPortSide: Int],
    counts: [PolicyCanvasPortSide: [PolicyCanvasPortMarkerEntry]]
  ) -> PolicyCanvasPortSide {
    let orderedSides = [preferred] + sides.filter { $0 != preferred }
    return orderedSides.first { side in
      counts[side, default: []].count < capacities[side, default: 1]
    } ?? orderedSides.min { left, right in
      counts[left, default: []].count < counts[right, default: []].count
    } ?? preferred
  }

  private func assignPortMarkerOffsets(
    entries: [PolicyCanvasPortMarkerEntry],
    side: PolicyCanvasPortSide,
    nodeIndex: [String: PolicyCanvasRouteNode],
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal]
  ) {
    guard
      let endpoint = entries.first?.endpoint
    else {
      return
    }
    let placements: [(entry: PolicyCanvasPortMarkerEntry, base: CGFloat)] =
      entries.compactMap { entry in
        guard
          let node = nodeIndex[entry.endpoint.nodeID],
          let basePoint = portAnchor(for: entry.endpoint, side: side, nodeIndex: nodeIndex)
        else {
          return nil
        }
        return (
          entry,
          policyCanvasLocalAxisCoordinate(basePoint, side: side, frame: node.frame)
        )
      }
      .sorted { left, right in
        abs(left.base - right.base) > 0.001 ? left.base < right.base : left.entry < right.entry
      }
    guard !placements.isEmpty else {
      return
    }
    let extent = policyCanvasSideExtent(side: side)
    let base = placements.count > 1 ? extent / 2 : placements[0].base
    let coordinates = policyCanvasPortMarkerCoordinates(
      count: placements.count,
      base: base,
      spacing: portMarkerSpacing(for: endpoint, side: side, nodeIndex: nodeIndex),
      extent: extent,
      inset: PolicyCanvasLayout.portDiameter / 2 + 4
    )
    for (placement, coordinate) in zip(placements, coordinates) {
      terminals[placement.entry.key] = PolicyCanvasPortTerminal(
        side: side,
        axisOffset: coordinate - placement.base
      )
    }
  }

  private func portMarkerCapacity(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> Int {
    let inset = PolicyCanvasLayout.portDiameter / 2 + 4
    let available = max(0, policyCanvasSideExtent(side: side) - (inset * 2))
    let spacing = portMarkerSpacing(for: endpoint, side: side, nodeIndex: nodeIndex)
    return max(1, Int(floor(available / spacing)) + 1)
  }

  private func portMarkerSpacing(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGFloat {
    max(
      portSpacing(for: endpoint, side: side, nodeIndex: nodeIndex),
      PolicyCanvasLayout.defaultEdgeLineSpacing + PolicyCanvasVisibilityRouter.channelStep
    )
  }
}

private struct PolicyCanvasPortMarkerEntry: Comparable {
  let key: PolicyCanvasRouteTerminalKey
  let endpoint: PolicyCanvasPortEndpoint
  let preferredSide: PolicyCanvasPortSide
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

private struct PolicyCanvasPortMarkerNodeKey: Hashable {
  let nodeID: String
  let kind: PolicyCanvasPortKind
}

private func policyCanvasPortMarkerSortKey(
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

private func policyCanvasPortMarkerCoordinates(
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

private func policyCanvasSideExtent(side: PolicyCanvasPortSide) -> CGFloat {
  switch side {
  case .leading, .trailing:
    PolicyCanvasLayout.nodeSize.height
  case .top, .bottom:
    PolicyCanvasLayout.nodeSize.width
  }
}

private func policyCanvasLocalAxisCoordinate(
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

private func policyCanvasSortedUniquePortMarkerOffsets(_ offsets: [CGFloat]) -> [CGFloat] {
  offsets.sorted().reduce(into: [CGFloat]()) { unique, offset in
    if unique.last.map({ abs($0 - offset) > 0.001 }) ?? true {
      unique.append(offset)
    }
  }
}
