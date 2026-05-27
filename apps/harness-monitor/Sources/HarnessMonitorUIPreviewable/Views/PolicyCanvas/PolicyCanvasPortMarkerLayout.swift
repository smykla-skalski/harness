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
    let familyPreferences = policyCanvasRouteFamilyPreferences(edges: edges)
    let entries = portMarkerEntries(routes: routes, familyPreferences: familyPreferences)
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
    routes: [String: PolicyCanvasEdgeRoute],
    familyPreferences: [String: PolicyCanvasRouteFamilyPreference]
  ) -> [PolicyCanvasPortMarkerEntry] {
    edges.flatMap { edge -> [PolicyCanvasPortMarkerEntry] in
      guard let route = routes[edge.id] else {
        return []
      }
      let familyPreference = familyPreferences[edge.id, default: .none]
      return [
        PolicyCanvasPortMarkerEntry(
          key: PolicyCanvasRouteTerminalKey(edgeID: edge.id, role: .source),
          endpoint: edge.source,
          preferredSide: policyCanvasRouteSourceSide(route)
            ?? policyCanvasResolvedPortSide(for: edge.source),
          collapsedTerminalGroup: policyCanvasCollapsedSourceTerminalGroup(
            edge: edge,
            familyPreference: familyPreference
          ),
          sortKey: policyCanvasPortMarkerSortKey(edge: edge, role: .source)
        ),
        PolicyCanvasPortMarkerEntry(
          key: PolicyCanvasRouteTerminalKey(edgeID: edge.id, role: .target),
          endpoint: edge.target,
          preferredSide: policyCanvasRouteTargetSide(route)
            ?? policyCanvasResolvedPortSide(for: edge.target),
          collapsedTerminalGroup: nil,
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
    let units = policyCanvasPortMarkerAssignmentUnits(entries, sides: sides)
    var unitsBySide = Dictionary(
      uniqueKeysWithValues: sides.map { ($0, [PolicyCanvasPortMarkerAssignmentUnit]()) }
    )
    let capacities = Dictionary(
      uniqueKeysWithValues: sides.map { side in
        (side, portMarkerCapacity(for: endpoint, side: side, nodeIndex: nodeIndex))
      })
    let preferredSidesByEndpoint = Dictionary(
      grouping: units,
      by: \.endpointKey
    ).compactMapValues { group -> PolicyCanvasPortSide? in
      guard
        let preferredSide = group.first?.preferredSide,
        group.allSatisfy({ $0.preferredSide == preferredSide })
      else {
        return nil
      }
      return preferredSide
    }
    let endpointGroups = Dictionary(grouping: units, by: \.endpointKey)
      .sorted { left, right in
        left.value.count == right.value.count
          ? left.key.portID < right.key.portID
          : left.value.count > right.value.count
      }
    var reservedUnitIDs: Set<String> = []
    for (endpointKey, groupUnits) in endpointGroups {
      guard
        let preferredSide = preferredSidesByEndpoint[endpointKey],
        unitsBySide[preferredSide, default: []].count + groupUnits.count
          <= capacities[preferredSide, default: 1]
      else {
        continue
      }
      unitsBySide[preferredSide, default: []].append(contentsOf: groupUnits)
      reservedUnitIDs.formUnion(groupUnits.map(\.id))
    }
    let remainingUnits = units.filter { !reservedUnitIDs.contains($0.id) }
    guard !remainingUnits.isEmpty else {
      for side in sides {
        assignPortMarkerOffsets(
          units: unitsBySide[side, default: []],
          side: side,
          nodeIndex: nodeIndex,
          terminals: &terminals
        )
      }
      return
    }
    let remainingCapacities = Dictionary(
      uniqueKeysWithValues: sides.map { side in
        (
          side,
          max(0, capacities[side, default: 1] - unitsBySide[side, default: []].count)
        )
      }
    )
    if let side = dominantSideThatFits(
      units: remainingUnits,
      sides: sides,
      capacities: remainingCapacities
    ) {
      unitsBySide[side, default: []].append(contentsOf: remainingUnits)
    } else {
      for unit in remainingUnits {
        let preferred = sides.contains(unit.preferredSide) ? unit.preferredSide : sides[0]
        let side = firstAvailableSide(
          preferred: preferred,
          sides: sides,
          capacities: capacities,
          counts: unitsBySide
        )
        unitsBySide[side, default: []].append(unit)
      }
    }
    for side in sides {
      assignPortMarkerOffsets(
        units: unitsBySide[side, default: []],
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
    counts: [PolicyCanvasPortSide: [PolicyCanvasPortMarkerAssignmentUnit]]
  ) -> PolicyCanvasPortSide {
    let orderedSides = [preferred] + sides.filter { $0 != preferred }
    return orderedSides.first { side in
      counts[side, default: []].count < capacities[side, default: 1]
    } ?? orderedSides.min { left, right in
      counts[left, default: []].count < counts[right, default: []].count
    } ?? preferred
  }

  private func dominantSideThatFits(
    units: [PolicyCanvasPortMarkerAssignmentUnit],
    sides: [PolicyCanvasPortSide],
    capacities: [PolicyCanvasPortSide: Int]
  ) -> PolicyCanvasPortSide? {
    guard units.count > 1 else {
      return nil
    }
    let preferredCounts = Dictionary(grouping: units) { unit in
      sides.contains(unit.preferredSide) ? unit.preferredSide : sides[0]
    }
    return
      sides
      .filter { side in
        preferredCounts[side, default: []].count > units.count / 2
          && capacities[side, default: 1] >= units.count
      }
      .max { left, right in
        preferredCounts[left, default: []].count < preferredCounts[right, default: []].count
      }
  }

  private func assignPortMarkerOffsets(
    units: [PolicyCanvasPortMarkerAssignmentUnit],
    side: PolicyCanvasPortSide,
    nodeIndex: [String: PolicyCanvasRouteNode],
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal]
  ) {
    guard
      let endpoint = units.first?.entries.first?.endpoint
    else {
      return
    }
    let placements: [(unit: PolicyCanvasPortMarkerAssignmentUnit, base: CGFloat)] =
      units.compactMap { unit in
        guard
          let entry = unit.entries.first,
          let node = nodeIndex[entry.endpoint.nodeID],
          let basePoint = portAnchor(for: entry.endpoint, side: side, nodeIndex: nodeIndex)
        else {
          return nil
        }
        return (
          unit,
          policyCanvasLocalAxisCoordinate(basePoint, side: side, frame: node.frame)
        )
      }
      .sorted { left, right in
        abs(left.base - right.base) > 0.001 ? left.base < right.base : left.unit < right.unit
      }
    guard !placements.isEmpty else {
      return
    }
    let extent = policyCanvasSideExtent(side: side)
    // Side-local port layout should not inherit the global port index from
    // sibling ports that render on the alternate side. A lone marker on a side
    // stays centered on that side even when other ports of the same kind fan
    // out elsewhere.
    let base = extent / 2
    let coordinates = policyCanvasPortMarkerCoordinates(
      count: placements.count,
      base: base,
      spacing: portMarkerSpacing(for: endpoint, side: side, nodeIndex: nodeIndex),
      extent: extent,
      inset: PolicyCanvasLayout.portDiameter / 2 + 4
    )
    for (placement, coordinate) in zip(placements, coordinates) {
      let terminal = PolicyCanvasPortTerminal(side: side, axisOffset: coordinate - placement.base)
      for entry in placement.unit.entries {
        terminals[entry.key] = terminal
      }
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

private struct PolicyCanvasPortMarkerAssignmentUnit: Comparable {
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

private func policyCanvasPortMarkerAssignmentUnits(
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
