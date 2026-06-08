import CoreGraphics

/// Flag routes that double back on themselves. Walking the polyline, a route
/// that has been progressing one way along an axis and then takes a segment the
/// opposite way along that same axis has reversed - the reversing segment is the
/// visible spur the user reads as a wrong turn. Only segments at least
/// `wrongTurnDepth` long set or reverse the running direction, so the
/// sub-port-marker jitter the lane spreader leaves near a terminal does not
/// register, and a clean staircase (monotone on each axis) never trips.
///
/// This catches the short terminal hooks the detour metric misses: a hook small
/// enough to stay under the detour excess budget still reverses an axis here.
func policyCanvasMeasureWrongTurns(
  routedEdges: [PolicyCanvasRoutedEdge],
  thresholds: PolicyCanvasGraphQualityThresholds
) -> [PolicyCanvasWrongTurnViolation] {
  var violations: [PolicyCanvasWrongTurnViolation] = []
  for routed in routedEdges {
    let points = routed.route.points
    guard points.count >= 3 else {
      continue
    }
    var lastHorizontalSign = 0
    var lastVerticalSign = 0
    for index in 1..<points.count {
      let start = points[index - 1]
      let end = points[index]
      let deltaX = end.x - start.x
      let deltaY = end.y - start.y
      if abs(deltaY) < 0.5, abs(deltaX) >= thresholds.wrongTurnDepth {
        let sign = deltaX > 0 ? 1 : -1
        if lastHorizontalSign != 0, sign != lastHorizontalSign {
          violations.append(
            PolicyCanvasWrongTurnViolation(
              edgeID: routed.edge.id,
              point: start,
              returnPoint: end,
              depth: abs(deltaX)
            )
          )
        }
        lastHorizontalSign = sign
      } else if abs(deltaX) < 0.5, abs(deltaY) >= thresholds.wrongTurnDepth {
        let sign = deltaY > 0 ? 1 : -1
        if lastVerticalSign != 0, sign != lastVerticalSign {
          violations.append(
            PolicyCanvasWrongTurnViolation(
              edgeID: routed.edge.id,
              point: start,
              returnPoint: end,
              depth: abs(deltaY)
            )
          )
        }
        lastVerticalSign = sign
      }
    }
  }
  return violations.sorted { lhs, rhs in
    abs(lhs.depth - rhs.depth) > 0.001 ? lhs.depth > rhs.depth : lhs.edgeID < rhs.edgeID
  }
}
