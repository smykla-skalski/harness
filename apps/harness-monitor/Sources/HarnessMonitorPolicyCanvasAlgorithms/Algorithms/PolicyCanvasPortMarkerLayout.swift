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

// Bundles the three per-group assignment inputs that flow unchanged through the
// side-assignment and offset-assignment helpers.
struct PolicyCanvasPortMarkerAssignmentContext {
  let edgesByID: [String: PolicyCanvasEdge]
  let nodeIndex: [String: PolicyCanvasRouteNode]
  let ordering: PolicyCanvasPortMarkerOrdering
}

// Bundles the routable sides for one node kind together with their computed
// capacities so they travel as a unit through firstAvailableSide.
struct PolicyCanvasPortSideCapacities {
  let sides: [PolicyCanvasPortSide]
  let capacities: [PolicyCanvasPortSide: Int]
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
    let context = PolicyCanvasPortMarkerAssignmentContext(
      edgesByID: edgesByID,
      nodeIndex: nodeIndex,
      ordering: ordering
    )
    var terminals: [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal] = [:]
    for groupEntries in groups.values {
      assignPortMarkerTerminals(
        entries: groupEntries.sorted(),
        context: context,
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
    context: PolicyCanvasPortMarkerAssignmentContext,
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal]
  ) {
    guard let kind = entries.first?.endpoint.kind else {
      return
    }
    let node = entries.first.flatMap { context.nodeIndex[$0.endpoint.nodeID] }
    let sides = policyCanvasRoutablePortSides(for: kind)
    let units = policyCanvasPortMarkerAssignmentUnits(entries, sides: sides)
    var unitsBySide = Dictionary(
      uniqueKeysWithValues: sides.map { ($0, [PolicyCanvasPortMarkerAssignmentUnit]()) }
    )
    let sideCapacities = PolicyCanvasPortSideCapacities(
      sides: sides,
      capacities: Dictionary(
        uniqueKeysWithValues: sides.map { side in
          (side, portMarkerCapacity(side: side, node: node))
        }
      )
    )
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
          <= sideCapacities.capacities[preferredSide, default: 1]
      else {
        continue
      }
      unitsBySide[preferredSide, default: []].append(contentsOf: groupUnits)
      reservedUnitIDs.formUnion(groupUnits.map(\.id))
    }
    let remainingUnits = units.filter { !reservedUnitIDs.contains($0.id) }
    guard !remainingUnits.isEmpty else {
      assignPortMarkerOffsetsForSides(
        unitsBySide: unitsBySide,
        sideCapacities: sideCapacities,
        context: context,
        terminals: &terminals
      )
      return
    }
    dispatchRemainingPortMarkerUnits(
      remainingUnits,
      sideCapacities: sideCapacities,
      unitsBySide: &unitsBySide,
      context: context
    )
    assignPortMarkerOffsetsForSides(
      unitsBySide: unitsBySide,
      sideCapacities: sideCapacities,
      context: context,
      terminals: &terminals
    )
  }

}
