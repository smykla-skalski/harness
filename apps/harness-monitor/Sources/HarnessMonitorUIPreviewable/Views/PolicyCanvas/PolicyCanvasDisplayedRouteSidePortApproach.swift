import SwiftUI

// Straighten the final approach into a leading/trailing port.
//
// A route entering a side port should arrive head-on: one straight horizontal
// at the port's Y. The corridor and bundle passes only align top/bottom
// terminals, so a route exiting its vertical corridor one lane off the port
// center keeps a short vertical jog wedged between the corridor-exit horizontal
// and the port stub - an H-V-H stair-step that reads on screen as an edge
// ending immediately after turning right.
//
// This pass extends the corridor vertical down to the port Y so the exit
// horizontal and the stub merge into one segment. It only fires when the result
// stays orthogonal, keeps the same port sides, and clears every obstacle, so a
// jog that genuinely dodges something is left untouched.
func policyCanvasTargetLocalSidePortApproachRoute(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest
) -> PolicyCanvasEdgeRoute {
  let count = route.points.count
  guard
    count >= 5,
    let sourceSide = policyCanvasRouteSourceSide(route),
    let targetSide = policyCanvasRouteTargetSide(route),
    targetSide == .leading || targetSide == .trailing
  else {
    return route
  }

  let target = route.points[count - 1]
  let stubStart = route.points[count - 2]
  let jogStart = route.points[count - 3]
  let exitStart = route.points[count - 4]
  let corridorStart = route.points[count - 5]

  // Tail shape: corridor vertical, exit horizontal, short vertical jog, stub.
  guard
    abs(stubStart.y - target.y) < 0.001, abs(stubStart.x - target.x) > 0.001,
    abs(jogStart.x - stubStart.x) < 0.001, abs(jogStart.y - stubStart.y) > 0.001,
    abs(exitStart.y - jogStart.y) < 0.001, abs(exitStart.x - jogStart.x) > 0.001,
    abs(corridorStart.x - exitStart.x) < 0.001, abs(corridorStart.y - exitStart.y) > 0.001
  else {
    return route
  }

  // Only collapse a small reconcile jog; a tall vertical near the target is a
  // real routing leg, not a lane-alignment artifact.
  guard abs(jogStart.y - stubStart.y) <= PolicyCanvasLayout.nodeSize.height else {
    return route
  }

  // The exit horizontal and the port stub must run the same direction, else
  // straightening them would fold the route back on itself.
  guard (jogStart.x - exitStart.x).sign == (target.x - stubStart.x).sign else {
    return route
  }

  let portY = target.y
  var points = route.points
  points[count - 4] = CGPoint(x: exitStart.x, y: portY)
  points[count - 3] = CGPoint(x: jogStart.x, y: portY)
  let compressed = PolicyCanvasVisibilityRouter.compressCollinear(points)
  let candidate = PolicyCanvasEdgeRoute(
    points: compressed,
    labelPosition: PolicyCanvasVisibilityRouter.labelPosition(for: compressed)
  )
  guard
    policyCanvasRouteIsOrthogonal(candidate),
    policyCanvasRouteSourceSide(candidate) == sourceSide,
    policyCanvasRouteTargetSide(candidate) == targetSide,
    !policyCanvasRouteIntersectsObstacles(candidate, obstacles: request.obstacles)
  else {
    return route
  }
  return candidate
}
