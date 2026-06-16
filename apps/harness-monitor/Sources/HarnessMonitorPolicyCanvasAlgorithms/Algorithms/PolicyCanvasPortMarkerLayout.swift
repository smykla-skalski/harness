import SwiftUI

public enum PolicyCanvasRouteEndpointRole: Hashable, Sendable {
  case source
  case target
}

struct PolicyCanvasRouteTerminalKey: Hashable, Sendable {
  let edgeID: String
  let role: PolicyCanvasRouteEndpointRole
}

public struct PolicyCanvasPortTerminal: Equatable, Sendable {
  public let side: PolicyCanvasPortSide
  public let axisOffset: CGFloat

  public init(side: PolicyCanvasPortSide, axisOffset: CGFloat) {
    self.side = side
    self.axisOffset = axisOffset
  }
}

public struct PolicyCanvasPortMarker: Identifiable, Hashable, Sendable {
  public let id: String
  public let axisOffset: CGFloat
  public let allowsInteraction: Bool

  public init(id: String, axisOffset: CGFloat, allowsInteraction: Bool) {
    self.id = id
    self.axisOffset = axisOffset
    self.allowsInteraction = allowsInteraction
  }
}

public struct PolicyCanvasPortMarkerLayout: Equatable, Sendable {
  private let terminalsByKey: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal]
  private let offsetsByEndpoint: [PolicyCanvasPortEndpoint: [PolicyCanvasPortSide: [CGFloat]]]

  public static let empty = Self(terminalsByKey: [:], endpointsByKey: [:])

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

  public func terminal(
    edgeID: String,
    role: PolicyCanvasRouteEndpointRole
  ) -> PolicyCanvasPortTerminal? {
    terminalsByKey[PolicyCanvasRouteTerminalKey(edgeID: edgeID, role: role)]
  }

  public func hasMarkers(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide
  ) -> Bool {
    offsetsByEndpoint[policyCanvasCanonicalPortEndpoint(endpoint)]?[side]?.isEmpty == false
  }

  public func markers(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    isVisible: Bool
  ) -> [PolicyCanvasPortMarker] {
    guard isVisible else {
      return []
    }
    let offsets: [CGFloat]
    if let sideOffsets = offsetsByEndpoint[policyCanvasCanonicalPortEndpoint(endpoint)] {
      guard let explicitOffsets = sideOffsets[side] else {
        return []
      }
      offsets = explicitOffsets
    } else {
      offsets = [0]
    }
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

extension PolicyCanvasPreparedRouteInput {
  public func portMarkerLayout(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasPortMarkerLayout {
    portMarkerLayout(routes: routes, nodeIndex: nodeIndex, ordering: .fanAngle)
  }

  func portMarkerLayout(
    routes: [String: PolicyCanvasEdgeRoute],
    nodeIndex: [String: PolicyCanvasRouteNode],
    ordering: PolicyCanvasPortMarkerOrdering
  ) -> PolicyCanvasPortMarkerLayout {
    portMarkerLayout(
      entries: portMarkerEntries(routes: routes),
      nodeIndex: nodeIndex,
      ordering: ordering
    )
  }

  func seededPortMarkerLayout(
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasPortMarkerLayout {
    portMarkerLayout(entries: seededPortMarkerEntries(), nodeIndex: nodeIndex, ordering: .fanAngle)
  }

  private func portMarkerLayout(
    entries: [PolicyCanvasPortMarkerEntry],
    nodeIndex: [String: PolicyCanvasRouteNode],
    ordering: PolicyCanvasPortMarkerOrdering
  ) -> PolicyCanvasPortMarkerLayout {
    let groups = Dictionary(grouping: entries) { $0.nodeKey }
    let edgesByID = Dictionary(edges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var terminals: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal] = [:]
    for groupEntries in groups.values {
      assignPortMarkerTerminals(
        entries: groupEntries.sorted(),
        edgesByID: edgesByID,
        nodeIndex: nodeIndex,
        ordering: ordering,
        terminals: &terminals
      )
    }
    return PolicyCanvasPortMarkerLayout(
      terminalsByKey: terminals,
      endpointsByKey: Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.endpoint) })
    )
  }

  private func seededPortMarkerEntries() -> [PolicyCanvasPortMarkerEntry] {
    edges.flatMap { edge -> [PolicyCanvasPortMarkerEntry] in
      [
        PolicyCanvasPortMarkerEntry(
          key: PolicyCanvasRouteTerminalKey(edgeID: edge.id, role: .source),
          endpoint: edge.source,
          preferredSide: policyCanvasResolvedPortSide(for: edge.source),
          sortKey: policyCanvasPortMarkerSortKey(edge: edge, role: .source)
        ),
        PolicyCanvasPortMarkerEntry(
          key: PolicyCanvasRouteTerminalKey(edgeID: edge.id, role: .target),
          endpoint: edge.target,
          preferredSide: policyCanvasResolvedPortSide(for: edge.target),
          sortKey: policyCanvasPortMarkerSortKey(edge: edge, role: .target)
        ),
      ]
    }
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
          preferredSide: policyCanvasResolvedRoutablePortSide(
            for: edge.source,
            preferredSide: policyCanvasRouteSourceSide(route)
          ),
          sortKey: policyCanvasPortMarkerSortKey(edge: edge, role: .source)
        ),
        PolicyCanvasPortMarkerEntry(
          key: PolicyCanvasRouteTerminalKey(edgeID: edge.id, role: .target),
          endpoint: edge.target,
          preferredSide: policyCanvasResolvedRoutablePortSide(
            for: edge.target,
            preferredSide: policyCanvasRouteTargetSide(route)
          ),
          sortKey: policyCanvasPortMarkerSortKey(edge: edge, role: .target)
        ),
      ]
    }
  }

  private func assignPortMarkerTerminals(
    entries: [PolicyCanvasPortMarkerEntry],
    edgesByID: [String: PolicyCanvasEdge],
    nodeIndex: [String: PolicyCanvasRouteNode],
    ordering: PolicyCanvasPortMarkerOrdering,
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal]
  ) {
    guard !entries.isEmpty else {
      return
    }
    let sides: [PolicyCanvasPortSide] = [.leading, .trailing]
    let units = policyCanvasPortMarkerAssignmentUnits(entries, sides: sides)
    var unitsBySide = Dictionary(
      uniqueKeysWithValues: sides.map { ($0, [PolicyCanvasPortMarkerAssignmentUnit]()) }
    )
    let capacities = Dictionary(
      uniqueKeysWithValues: sides.map { side in
        (side, portMarkerCapacity(side: side))
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
          ? policyCanvasPortMarkerEndpointGroupSortKey(left)
            < policyCanvasPortMarkerEndpointGroupSortKey(right)
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
      assignPortMarkerOffsetsForSides(
        sides,
        unitsBySide: unitsBySide,
        edgesByID: edgesByID,
        nodeIndex: nodeIndex,
        ordering: ordering,
        terminals: &terminals
      )
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
          unit: unit,
          preferred: preferred,
          sides: sides,
          capacities: capacities,
          counts: unitsBySide,
          edgesByID: edgesByID,
          nodeIndex: nodeIndex
        )
        unitsBySide[side, default: []].append(unit)
      }
    }
    assignPortMarkerOffsetsForSides(
      sides,
      unitsBySide: unitsBySide,
      edgesByID: edgesByID,
      nodeIndex: nodeIndex,
      ordering: ordering,
      terminals: &terminals
    )
  }

  private func assignPortMarkerOffsetsForSides(
    _ sides: [PolicyCanvasPortSide],
    unitsBySide: [PolicyCanvasPortSide: [PolicyCanvasPortMarkerAssignmentUnit]],
    edgesByID: [String: PolicyCanvasEdge],
    nodeIndex: [String: PolicyCanvasRouteNode],
    ordering: PolicyCanvasPortMarkerOrdering,
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal]
  ) {
    for side in sides {
      assignPortMarkerOffsets(
        units: unitsBySide[side, default: []],
        side: side,
        edgesByID: edgesByID,
        nodeIndex: nodeIndex,
        ordering: ordering,
        terminals: &terminals
      )
    }
  }

  private func firstAvailableSide(
    unit: PolicyCanvasPortMarkerAssignmentUnit,
    preferred: PolicyCanvasPortSide,
    sides: [PolicyCanvasPortSide],
    capacities: [PolicyCanvasPortSide: Int],
    counts: [PolicyCanvasPortSide: [PolicyCanvasPortMarkerAssignmentUnit]],
    edgesByID: [String: PolicyCanvasEdge],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> PolicyCanvasPortSide {
    let orderedSides = [preferred] + sides.filter { $0 != preferred }
    let availableSides = orderedSides.filter { side in
      counts[side, default: []].count < capacities[side, default: 1]
    }
    if let unblocked = availableSides.first(where: { side in
      !portMarkerSideIsBlocked(
        unit: unit,
        side: side,
        edgesByID: edgesByID,
        nodeIndex: nodeIndex
      )
    }) {
      return unblocked
    }
    return availableSides.first ?? orderedSides.min { left, right in
      counts[left, default: []].count < counts[right, default: []].count
    } ?? preferred
  }

  private func portMarkerSideIsBlocked(
    unit: PolicyCanvasPortMarkerAssignmentUnit,
    side: PolicyCanvasPortSide,
    edgesByID: [String: PolicyCanvasEdge],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> Bool {
    guard
      let endpoint = unit.entries.first?.endpoint,
      let node = nodeIndex[endpoint.nodeID]
    else {
      return false
    }
    let endpointNodeIDs = Set(
      unit.entries.compactMap { entry -> String? in
        guard let edge = edgesByID[entry.key.edgeID] else {
          return nil
        }
        return entry.key.role == .source ? edge.target.nodeID : edge.source.nodeID
      } + [endpoint.nodeID]
    )
    let reach = PolicyCanvasLayout.edgePortTurnMinimumLead + 1
    let corridor: CGRect
    switch side {
    case .leading:
      corridor = CGRect(
        x: node.frame.minX - reach,
        y: node.frame.minY,
        width: reach,
        height: node.frame.height
      )
    case .trailing:
      corridor = CGRect(
        x: node.frame.maxX,
        y: node.frame.minY,
        width: reach,
        height: node.frame.height
      )
    case .top:
      corridor = CGRect(
        x: node.frame.minX,
        y: node.frame.minY - reach,
        width: node.frame.width,
        height: reach
      )
    case .bottom:
      corridor = CGRect(
        x: node.frame.minX,
        y: node.frame.maxY,
        width: node.frame.width,
        height: reach
      )
    }
    return nodeIndex.values.contains { other in
      !endpointNodeIDs.contains(other.id) && other.frame.intersects(corridor)
    }
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
    var dominantSide: PolicyCanvasPortSide?
    var dominantCount = -1
    for side in sides
    where
      preferredCounts[side, default: []].count > units.count / 2
      && capacities[side, default: 1] >= units.count
    {
      let count = preferredCounts[side, default: []].count
      if count > dominantCount {
        dominantSide = side
        dominantCount = count
      }
    }
    return dominantSide
  }

  private func assignPortMarkerOffsets(
    units: [PolicyCanvasPortMarkerAssignmentUnit],
    side: PolicyCanvasPortSide,
    edgesByID: [String: PolicyCanvasEdge],
    nodeIndex: [String: PolicyCanvasRouteNode],
    ordering: PolicyCanvasPortMarkerOrdering,
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal]
  ) {
    guard
      let endpoint = units.first?.entries.first?.endpoint
    else {
      return
    }
    let placements: [PolicyCanvasPortMarkerPlacement] =
      units.compactMap { unit in
        guard
          let entry = unit.entries.first,
          let node = nodeIndex[entry.endpoint.nodeID],
          let basePoint = portAnchor(for: entry.endpoint, side: side, nodeIndex: nodeIndex)
        else {
          return nil
        }
        let base = policyCanvasLocalAxisCoordinate(basePoint, side: side, frame: node.frame)
        // Order ports along the side by the selected comb order, not by natural
        // port index. The production order preserves existing sample budgets;
        // targeted repair passes may request metric-aligned far-axis ordering.
        let order =
          policyCanvasFarEndpointAnchor(unit: unit, edgesByID: edgesByID, nodeIndex: nodeIndex)
          .map { farAnchor in
            policyCanvasPortMarkerOrderKey(
              ordering: ordering,
              side: side,
              sideCenter: policyCanvasSideCenter(side: side, frame: node.frame),
              farAnchor: farAnchor
            )
          } ?? 0
        return PolicyCanvasPortMarkerPlacement(unit: unit, base: base, order: order)
      }
      .sorted { left, right in
        if abs(left.order - right.order) > 0.001 {
          return left.order < right.order
        }
        return abs(left.base - right.base) > 0.001 ? left.base < right.base : left.unit < right.unit
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
      inset: policyCanvasPortMarkerInset()
    )
    for (placement, coordinate) in zip(placements, coordinates) {
      let terminal = PolicyCanvasPortTerminal(side: side, axisOffset: coordinate - placement.base)
      for entry in placement.unit.entries {
        terminals[entry.key] = terminal
      }
    }
  }

  private func policyCanvasFarEndpointAnchor(
    unit: PolicyCanvasPortMarkerAssignmentUnit,
    edgesByID: [String: PolicyCanvasEdge],
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGPoint? {
    var sumX: CGFloat = 0
    var sumY: CGFloat = 0
    var count = 0
    for entry in unit.entries {
      guard let edge = edgesByID[entry.key.edgeID] else {
        continue
      }
      let farEndpoint = entry.key.role == .source ? edge.target : edge.source
      guard let anchor = portAnchor(for: farEndpoint, nodeIndex: nodeIndex) else {
        continue
      }
      sumX += anchor.x
      sumY += anchor.y
      count += 1
    }
    guard count > 0 else {
      return nil
    }
    return CGPoint(x: sumX / CGFloat(count), y: sumY / CGFloat(count))
  }

  private func portMarkerCapacity(side: PolicyCanvasPortSide) -> Int {
    let inset = policyCanvasPortMarkerInset()
    let available = max(0, policyCanvasSideExtent(side: side) - (inset * 2))
    // Capacity is how many markers fit at the minimum channel spacing before
    // they would overlap, not the wider preferred port spacing. A logical port
    // that fans into several markers compresses to this floor rather than
    // spilling onto an adjacent side.
    return max(1, Int(floor(available / policyCanvasMinimumPortMarkerSpacing())) + 1)
  }

  private func policyCanvasPortMarkerEndpointGroupSortKey(
    _ group: (key: PolicyCanvasPortEndpoint, value: [PolicyCanvasPortMarkerAssignmentUnit])
  ) -> String {
    let sortKey = group.value.map(\.sortKey).min() ?? ""
    return [sortKey, group.key.portID].joined(separator: "|")
  }

  private func portMarkerSpacing(
    for endpoint: PolicyCanvasPortEndpoint,
    side: PolicyCanvasPortSide,
    nodeIndex: [String: PolicyCanvasRouteNode]
  ) -> CGFloat {
    max(
      portSpacing(for: endpoint, side: side, nodeIndex: nodeIndex),
      policyCanvasMinimumPortMarkerSpacing()
    )
  }
}
