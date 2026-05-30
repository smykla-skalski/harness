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
    let edgesByID = Dictionary(edges.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var terminals: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal] = [:]
    for groupEntries in groups.values {
      assignPortMarkerTerminals(
        entries: groupEntries.sorted(),
        edgesByID: edgesByID,
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
    edgesByID: [String: PolicyCanvasEdge],
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
          edgesByID: edgesByID,
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
        edgesByID: edgesByID,
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
    edgesByID: [String: PolicyCanvasEdge],
    nodeIndex: [String: PolicyCanvasRouteNode],
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
        // Order ports along the side by the angle each edge takes as it leaves
        // the node, not by the natural port index. The departure angle is the
        // crossing-free order around the node even when two far endpoints share
        // a column or row - a single-axis projection ties there and falls back
        // to the index, letting the fan twist and cross right at the node.
        let order =
          policyCanvasFarEndpointAnchor(unit: unit, edgesByID: edgesByID, nodeIndex: nodeIndex)
          .map { farAnchor in
            policyCanvasFanOrderKey(
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
      inset: PolicyCanvasLayout.portDiameter / 2 + 4
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
    let inset = PolicyCanvasLayout.portDiameter / 2 + 4
    let available = max(0, policyCanvasSideExtent(side: side) - (inset * 2))
    // Capacity is how many markers fit at the minimum channel spacing before
    // they would overlap, not the wider preferred port spacing. A logical port
    // that fans into several markers compresses to this floor rather than
    // spilling onto an adjacent side.
    let spacing =
      PolicyCanvasLayout.defaultEdgeLineSpacing + PolicyCanvasVisibilityRouter.channelStep
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
