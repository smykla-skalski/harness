import CoreGraphics

/// One wire terminal resolved onto a node side: where it attaches (`offset`
/// along the side, `point` in content space) and where it comes from (`far`,
/// the opposite route endpoint projected onto the same axis).
private struct PolicyCanvasSideTerminal {
  let edgeID: String
  let offset: CGFloat
  let far: CGFloat
  let point: CGPoint
}

/// Measure wires that picked the wrong port: two edges on one node side whose
/// attach order along that side is inverted relative to where they come from, so
/// the wires cross between the node and their far ends. The crossing-free order
/// is the order of the far endpoints along the side axis (the same far-endpoint
/// ordering the port-marker layout aims for); an adjacent pair that disagrees is
/// a swap the layout should have made. These are crossings between edges that
/// share the node, which the independent-crossing metric deliberately ignores,
/// so they need their own signal.
func policyCanvasMeasureCrossedPorts(
  routedEdges: [PolicyCanvasRoutedEdge],
  nodeFramesByID: [String: CGRect]
) -> [PolicyCanvasCrossedPortsViolation] {
  let tolerance = PolicyCanvasLayout.portDiameter
  var byNodeSide: [String: [PolicyCanvasPortSide: [PolicyCanvasSideTerminal]]] = [:]
  for routed in routedEdges {
    guard let first = routed.route.points.first, let last = routed.route.points.last else {
      continue
    }
    policyCanvasRegisterSideTerminal(
      point: first,
      far: last,
      nodeID: routed.edge.source.nodeID,
      edgeID: routed.edge.id,
      nodeFramesByID: nodeFramesByID,
      tolerance: tolerance,
      byNodeSide: &byNodeSide
    )
    policyCanvasRegisterSideTerminal(
      point: last,
      far: first,
      nodeID: routed.edge.target.nodeID,
      edgeID: routed.edge.id,
      nodeFramesByID: nodeFramesByID,
      tolerance: tolerance,
      byNodeSide: &byNodeSide
    )
  }
  var violations: [PolicyCanvasCrossedPortsViolation] = []
  for (nodeID, sideMap) in byNodeSide {
    for (side, terminals) in sideMap where terminals.count >= 2 {
      let sorted = terminals.sorted {
        abs($0.offset - $1.offset) > 0.5 ? $0.offset < $1.offset : $0.edgeID < $1.edgeID
      }
      for index in 1..<sorted.count {
        let lower = sorted[index - 1]
        let upper = sorted[index]
        // Distinct attach points coming from distinct far positions, inverted:
        // the earlier port is fed from farther along the axis than the later one.
        guard
          abs(lower.offset - upper.offset) > 0.5,
          abs(lower.far - upper.far) > 0.5,
          lower.far > upper.far
        else {
          continue
        }
        violations.append(
          PolicyCanvasCrossedPortsViolation(
            nodeID: nodeID,
            side: side,
            edgeA: lower.edgeID,
            edgeB: upper.edgeID,
            pointA: lower.point,
            pointB: upper.point
          )
        )
      }
    }
  }
  return violations.sorted(by: policyCanvasCrossedPortsOrder)
}

private func policyCanvasRegisterSideTerminal(
  point: CGPoint,
  far: CGPoint,
  nodeID: String,
  edgeID: String,
  nodeFramesByID: [String: CGRect],
  tolerance: CGFloat,
  byNodeSide: inout [String: [PolicyCanvasPortSide: [PolicyCanvasSideTerminal]]]
) {
  guard
    let frame = nodeFramesByID[nodeID],
    let side = policyCanvasMarkerSide(point: point, frame: frame, tolerance: tolerance)
  else {
    return
  }
  let horizontalSide = side == .leading || side == .trailing
  let terminal = PolicyCanvasSideTerminal(
    edgeID: edgeID,
    offset: horizontalSide ? point.y : point.x,
    far: horizontalSide ? far.y : far.x,
    point: point
  )
  byNodeSide[nodeID, default: [:]][side, default: []].append(terminal)
}

private func policyCanvasCrossedPortsOrder(
  _ lhs: PolicyCanvasCrossedPortsViolation,
  _ rhs: PolicyCanvasCrossedPortsViolation
) -> Bool {
  if lhs.nodeID != rhs.nodeID {
    return lhs.nodeID < rhs.nodeID
  }
  if lhs.side != rhs.side {
    return lhs.side.rawValue < rhs.side.rawValue
  }
  if abs(lhs.pointA.y - rhs.pointA.y) > 0.001 {
    return lhs.pointA.y < rhs.pointA.y
  }
  return lhs.pointA.x < rhs.pointA.x
}
