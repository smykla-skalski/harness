import SwiftUI

// Side assignment and offset computation for port marker layout. All functions
// here are internal so they can be called from both the main layout file and
// from tests without crossing module boundaries.

extension PolicyCanvasPreparedRouteInput {
  func assignPortMarkerOffsetsForSides(
    unitsBySide: [PolicyCanvasPortSide: [PolicyCanvasPortMarkerAssignmentUnit]],
    sideCapacities: PolicyCanvasPortSideCapacities,
    context: PolicyCanvasPortMarkerAssignmentContext,
    terminals: inout [PolicyCanvasRouteTerminalKey: PolicyCanvasPortTerminal]
  ) {
    for side in sideCapacities.sides {
      assignPortMarkerOffsets(
        units: unitsBySide[side, default: []],
        side: side,
        context: context,
        terminals: &terminals
      )
    }
  }

  func firstAvailableSide(
    unit: PolicyCanvasPortMarkerAssignmentUnit,
    preferred: PolicyCanvasPortSide,
    sideCapacities: PolicyCanvasPortSideCapacities,
    counts: [PolicyCanvasPortSide: [PolicyCanvasPortMarkerAssignmentUnit]],
    context: PolicyCanvasPortMarkerAssignmentContext
  ) -> PolicyCanvasPortSide {
    let orderedSides = [preferred] + sideCapacities.sides.filter { $0 != preferred }
    let availableSides = orderedSides.filter { side in
      counts[side, default: []].count < sideCapacities.capacities[side, default: 1]
    }
    if let unblocked = availableSides.first(where: { side in
      !portMarkerSideIsBlocked(
        unit: unit,
        side: side,
        context: context
      )
    }) {
      return unblocked
    }
    return availableSides.first ?? orderedSides.min { left, right in
      counts[left, default: []].count < counts[right, default: []].count
    } ?? preferred
  }

  func portMarkerSideIsBlocked(
    unit: PolicyCanvasPortMarkerAssignmentUnit,
    side: PolicyCanvasPortSide,
    context: PolicyCanvasPortMarkerAssignmentContext
  ) -> Bool {
    guard
      let endpoint = unit.entries.first?.endpoint,
      let node = context.nodeIndex[endpoint.nodeID]
    else {
      return false
    }
    let endpointNodeIDs = Set(
      unit.entries.compactMap { entry -> String? in
        guard let edge = context.edgesByID[entry.key.edgeID] else {
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
    return context.nodeIndex.values.contains { other in
      !endpointNodeIDs.contains(other.id) && other.frame.intersects(corridor)
    }
  }

  func dominantSideThatFits(
    units: [PolicyCanvasPortMarkerAssignmentUnit],
    sideCapacities: PolicyCanvasPortSideCapacities
  ) -> PolicyCanvasPortSide? {
    guard units.count > 1 else {
      return nil
    }
    let sides = sideCapacities.sides
    let capacities = sideCapacities.capacities
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

  func dispatchRemainingPortMarkerUnits(
    _ remainingUnits: [PolicyCanvasPortMarkerAssignmentUnit],
    sideCapacities: PolicyCanvasPortSideCapacities,
    unitsBySide: inout [PolicyCanvasPortSide: [PolicyCanvasPortMarkerAssignmentUnit]],
    context: PolicyCanvasPortMarkerAssignmentContext
  ) {
    if let side = dominantSideThatFits(units: remainingUnits, sideCapacities: sideCapacities) {
      unitsBySide[side, default: []].append(contentsOf: remainingUnits)
      return
    }
    for unit in remainingUnits {
      let preferred =
        sideCapacities.sides.contains(unit.preferredSide)
        ? unit.preferredSide : sideCapacities.sides[0]
      let side = firstAvailableSide(
        unit: unit,
        preferred: preferred,
        sideCapacities: sideCapacities,
        counts: unitsBySide,
        context: context
      )
      unitsBySide[side, default: []].append(unit)
    }
  }

  func assignPortMarkerOffsets(
    units: [PolicyCanvasPortMarkerAssignmentUnit],
    side: PolicyCanvasPortSide,
    context: PolicyCanvasPortMarkerAssignmentContext,
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
          let node = context.nodeIndex[entry.endpoint.nodeID],
          let basePoint = portAnchor(
            for: entry.endpoint, side: side, nodeIndex: context.nodeIndex)
        else {
          return nil
        }
        let base = policyCanvasLocalAxisCoordinate(basePoint, side: side, frame: node.frame)
        // Order ports along the side by the selected comb order, not by natural
        // port index. The production order preserves existing sample budgets;
        // targeted repair passes may request metric-aligned far-axis ordering.
        let order =
          policyCanvasFarEndpointAnchor(unit: unit, context: context)
          .map { farAnchor in
            policyCanvasPortMarkerOrderKey(
              ordering: context.ordering,
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
    let extent =
      context.nodeIndex[endpoint.nodeID].map {
        policyCanvasSideExtent(side: side, frame: $0.frame)
      } ?? policyCanvasSideExtent(side: side)
    // Side-local port layout should not inherit the global port index from
    // sibling ports that render on the alternate side. A lone marker on a side
    // stays centered on that side even when other ports of the same kind fan
    // out elsewhere.
    let base = extent / 2
    let coordinates = policyCanvasPortMarkerCoordinates(
      count: placements.count,
      base: base,
      spacing: portMarkerSpacing(for: endpoint, side: side, nodeIndex: context.nodeIndex),
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

  func policyCanvasFarEndpointAnchor(
    unit: PolicyCanvasPortMarkerAssignmentUnit,
    context: PolicyCanvasPortMarkerAssignmentContext
  ) -> CGPoint? {
    var sumX: CGFloat = 0
    var sumY: CGFloat = 0
    var count = 0
    for entry in unit.entries {
      guard let edge = context.edgesByID[entry.key.edgeID] else {
        continue
      }
      let farEndpoint = entry.key.role == .source ? edge.target : edge.source
      guard let anchor = portAnchor(for: farEndpoint, nodeIndex: context.nodeIndex) else {
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

  func portMarkerCapacity(
    side: PolicyCanvasPortSide,
    node: PolicyCanvasRouteNode?
  ) -> Int {
    let inset = policyCanvasPortMarkerInset()
    let extent =
      node.map { policyCanvasSideExtent(side: side, frame: $0.frame) }
      ?? policyCanvasSideExtent(side: side)
    let available = max(0, extent - (inset * 2))
    // Capacity is how many markers fit at the minimum channel spacing before
    // they would overlap, not the wider preferred port spacing. A logical port
    // that fans into several markers compresses to this floor rather than
    // spilling onto an adjacent side.
    return max(1, Int(floor(available / policyCanvasMinimumPortMarkerSpacing())) + 1)
  }

  func policyCanvasPortMarkerEndpointGroupSortKey(
    _ group: (key: PolicyCanvasPortEndpoint, value: [PolicyCanvasPortMarkerAssignmentUnit])
  ) -> String {
    let sortKey = group.value.map(\.sortKey).min() ?? ""
    return [sortKey, group.key.portID].joined(separator: "|")
  }

  func portMarkerSpacing(
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
