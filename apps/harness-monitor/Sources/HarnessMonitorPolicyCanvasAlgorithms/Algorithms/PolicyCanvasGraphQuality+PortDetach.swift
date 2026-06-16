import CoreGraphics

/// Measure wires that do not reach their port marker. Every routed edge attaches
/// at `route.points.first` (source) / `.last` (target), and the canvas draws a
/// port dot at the marker center the port-marker layout settled on. When those
/// two points diverge - the routing pass and the marker-placement pass disagreed
/// on which side or offset the terminal sits at - the wire visibly ends in empty
/// space away from its dot. The gap between the wire end and the dot is the
/// signal; anything past `portDetachDistance` reads as detached.
///
/// This needs the rendered `PolicyCanvasPortMarkerLayout` (the same one the canvas
/// draws from), not a recomputed one: the whole point is to catch the case where
/// the routes and the marker layout the canvas actually shows disagree.
func policyCanvasMeasurePortDetachment(
  routedEdges: [PolicyCanvasRoutedEdge],
  nodesByID: [String: PolicyCanvasNode],
  nodeSizes: [String: CGSize] = [:],
  portMarkerLayout: PolicyCanvasPortMarkerLayout,
  thresholds: PolicyCanvasGraphQualityThresholds
) -> [PolicyCanvasPortSpacingViolation] {
  var violations: [PolicyCanvasPortSpacingViolation] = []
  for routed in routedEdges {
    guard let first = routed.route.points.first, let last = routed.route.points.last else {
      continue
    }
    for terminal in [
      (role: PolicyCanvasRouteEndpointRole.source, endpoint: routed.edge.source, point: first),
      (role: PolicyCanvasRouteEndpointRole.target, endpoint: routed.edge.target, point: last),
    ] {
      guard
        let placed = portMarkerLayout.terminal(edgeID: routed.edge.id, role: terminal.role),
        let center = policyCanvasPortMarkerCenter(
          endpoint: terminal.endpoint,
          terminal: placed,
          nodesByID: nodesByID,
          nodeSizes: nodeSizes
        )
      else {
        continue
      }
      let gap = hypot(terminal.point.x - center.x, terminal.point.y - center.y)
      guard gap > thresholds.portDetachDistance else {
        continue
      }
      violations.append(
        PolicyCanvasPortSpacingViolation(
          kind: .detached,
          nodeID: terminal.endpoint.nodeID,
          side: placed.side,
          point: center,
          otherPoint: terminal.point,
          gap: gap,
          edgeIDs: [routed.edge.id]
        )
      )
    }
  }
  return violations.sorted(by: policyCanvasPortSpacingViolationOrder)
}

/// Content-space center of the rendered port dot for one edge terminal: the
/// node-side port anchor shifted by the marker's axis offset. Mirrors the
/// canvas's own marker placement (`PolicyCanvasPortColumn` / the hit-test anchor),
/// so the comparison is against the dot the user actually sees.
func policyCanvasPortMarkerCenter(
  endpoint: PolicyCanvasPortEndpoint,
  terminal: PolicyCanvasPortTerminal,
  nodesByID: [String: PolicyCanvasNode],
  nodeSizes: [String: CGSize] = [:]
) -> CGPoint? {
  guard let node = nodesByID[endpoint.nodeID] else {
    return nil
  }
  let ports = endpoint.kind == .input ? node.inputPorts : node.outputPorts
  guard let index = ports.firstIndex(where: { $0.id == endpoint.portID }) else {
    return nil
  }
  let base = policyCanvasPortAnchorBase(
    position: node.position,
    side: terminal.side,
    index: index,
    count: ports.count,
    nodeSize: nodeSizes[node.id] ?? PolicyCanvasLayout.nodeSize(for: node)
  )
  return policyCanvasShiftedRouteAnchor(base, side: terminal.side, terminal: terminal)
}

/// The base port anchor on a node side before the per-marker axis shift, in
/// content space. Matches `PolicyCanvasViewModel.portAnchor(for:side:index:count:)`.
private func policyCanvasPortAnchorBase(
  position: CGPoint,
  side: PolicyCanvasPortSide,
  index: Int,
  count: Int,
  nodeSize: CGSize
) -> CGPoint {
  switch side {
  case .leading:
    CGPoint(
      x: position.x,
      y: position.y
        + PolicyCanvasLayout.portY(
          index: index,
          count: count,
          nodeHeight: nodeSize.height
        )
    )
  case .trailing:
    CGPoint(
      x: position.x + nodeSize.width,
      y: position.y
        + PolicyCanvasLayout.portY(
          index: index,
          count: count,
          nodeHeight: nodeSize.height
        )
    )
  case .top:
    CGPoint(
      x: position.x
        + PolicyCanvasLayout.portX(
          index: index,
          count: count,
          nodeWidth: nodeSize.width
        ),
      y: position.y
    )
  case .bottom:
    CGPoint(
      x: position.x
        + PolicyCanvasLayout.portX(
          index: index,
          count: count,
          nodeWidth: nodeSize.width
        ),
      y: position.y + nodeSize.height
    )
  }
}
