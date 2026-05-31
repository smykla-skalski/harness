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

  // Collapse a small reconcile jog, OR a climb that overshoots the port: the
  // corridor approaches from one side of the port Y while the exit horizontal
  // sits on the far side, so the jog exists only to walk back onto the port (an
  // entry node feeding the first node of a chain above it climbs over the row
  // then drops onto the leading port). Both are alignment artifacts. A tall
  // vertical that stays on the corridor's side of the port is a real routing leg
  // and is left alone. The orthogonality, port-side, and obstacle checks below
  // still gate every collapse.
  let jogIsSmall = abs(jogStart.y - stubStart.y) <= PolicyCanvasLayout.nodeSize.height
  let exitOvershootsPort = (corridorStart.y - target.y).sign != (exitStart.y - target.y).sign
  guard jogIsSmall || exitOvershootsPort else {
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

// Straighten the final approach into a top/bottom port fed from a side exit.
//
// A source leaving its trailing (or leading) edge toward a target below it turns
// down at its escape lead, then has to step sideways to line up with the target's
// port column - an H-V-H-V stair that reads as the edge jogging right (or left)
// just before it lands. This pass extends the escape horizontal straight to the
// target column so the final descent is one clean vertical.
//
// It only fires when the reconcile jog is small and runs the same direction as the
// overall progression (a backward jog is a genuine dodge, left alone), and when the
// result stays orthogonal, keeps the same port sides, and clears every obstacle.
func policyCanvasTargetLocalVerticalPortApproachRoute(
  _ route: PolicyCanvasEdgeRoute,
  request: PolicyCanvasResolvedDisplayedRouteRequest
) -> PolicyCanvasEdgeRoute {
  let count = route.points.count
  guard
    count >= 5,
    let sourceSide = policyCanvasRouteSourceSide(route),
    let targetSide = policyCanvasRouteTargetSide(route),
    targetSide == .top || targetSide == .bottom
  else {
    return route
  }

  let target = route.points[count - 1]
  let stubStart = route.points[count - 2]
  let jogStart = route.points[count - 3]
  let exitStart = route.points[count - 4]
  let corridorStart = route.points[count - 5]

  // Tail shape: exit horizontal, escape vertical, reconcile horizontal, port stub.
  guard
    abs(stubStart.x - target.x) < 0.001, abs(stubStart.y - target.y) > 0.001,
    abs(jogStart.y - stubStart.y) < 0.001, abs(jogStart.x - stubStart.x) > 0.001,
    abs(exitStart.x - jogStart.x) < 0.001, abs(exitStart.y - jogStart.y) > 0.001,
    abs(corridorStart.y - exitStart.y) < 0.001, abs(corridorStart.x - exitStart.x) > 0.001
  else {
    return route
  }

  // Only collapse a small reconcile jog; a long horizontal near the target is a
  // real routing leg, not a lane-alignment artifact.
  guard abs(jogStart.x - stubStart.x) <= PolicyCanvasLayout.nodeSize.width else {
    return route
  }

  // The reconcile jog must continue in the overall horizontal direction, else
  // straightening it would fold the route back on itself.
  guard (stubStart.x - jogStart.x).sign == (target.x - corridorStart.x).sign else {
    return route
  }

  var points = route.points
  points[count - 4] = CGPoint(x: target.x, y: corridorStart.y)
  points[count - 3] = CGPoint(x: target.x, y: jogStart.y)
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
