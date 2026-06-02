import SwiftUI

/// Coordinated label placement for a fan-in family: several edges carrying the
/// same text whose dominant horizontal runs stack close together as they fan
/// into one node (the canonical "evidence failure" x4 into supervisor:merge-deny).
///
/// Greedy per-label placement crowds badly here. The runs sit one label-height
/// apart, so once a through-route's label claims the open middle the fan labels
/// get shoved against the bends they just turned off - no clearance after the
/// corner, and the family reads as a left-justified pile rather than a stair.
/// Placing the family together, before the greedy pass, lets it claim a tidy
/// staircase down the open middle of its runs: each label steps one notch along
/// the x axis as the run descends, so they never stack and every one keeps
/// clearance from its turn. Members the staircase cannot seat (no clear window)
/// are simply left out and fall back to the greedy placer.
func policyCanvasFanInLabelStaircasePositions(
  routes: [PolicyCanvasLabelPlacementRoute],
  nodeFrames: [CGRect]
) -> [String: CGPoint] {
  // Thin per-edge frames - the label only needs to avoid sitting ON another
  // edge, not honour the wide spacing pad that `policyCanvasRouteFrames` adds
  // (that pad reserves a full lane around every segment and would report the
  // open middle as fully blocked whenever a through-bus runs a lane above the
  // fan, exactly the case this staircase exists to handle).
  let edgeFrames = Dictionary(
    uniqueKeysWithValues: routes.map { ($0.id, policyCanvasThinRouteFrames($0.route)) }
  )
  var result: [String: CGPoint] = [:]
  for (_, members) in Dictionary(grouping: routes, by: { $0.label }) {
    guard members.count >= 3 else {
      continue
    }
    let fan = members.compactMap(PolicyCanvasFanInLabelMember.init(route:))
      .sorted { $0.runY < $1.runY }
    guard fan.count >= 3, policyCanvasRunsFormTightStack(fan) else {
      continue
    }
    for (id, center) in policyCanvasStaircasePlacement(
      fan,
      nodeFrames: nodeFrames,
      edgeFrames: edgeFrames
    ) {
      result[id] = center
    }
  }
  return result
}

func policyCanvasThinRouteFrames(_ route: PolicyCanvasEdgeRoute) -> [CGRect] {
  zip(route.points, route.points.dropFirst()).map { start, end in
    CGRect(
      x: min(start.x, end.x),
      y: min(start.y, end.y),
      width: abs(end.x - start.x),
      height: abs(end.y - start.y)
    ).insetBy(dx: -2, dy: -2)
  }
}

struct PolicyCanvasFanInLabelMember {
  let id: String
  let size: CGSize
  let runStart: CGPoint
  let runEnd: CGPoint

  var runY: CGFloat { runStart.y }
  var runLow: CGFloat { min(runStart.x, runEnd.x) }
  var runHigh: CGFloat { max(runStart.x, runEnd.x) }

  init?(route: PolicyCanvasLabelPlacementRoute) {
    let points = route.route.points
    var start = CGPoint.zero
    var end = CGPoint.zero
    var length: CGFloat = -1
    var runIndex = -1
    for index in 0..<max(0, points.count - 1) {
      let segmentStart = points[index]
      let segmentEnd = points[index + 1]
      guard abs(segmentStart.y - segmentEnd.y) < 0.5, abs(segmentStart.x - segmentEnd.x) > 0.5
      else {
        continue
      }
      let candidateLength = abs(segmentEnd.x - segmentStart.x)
      if candidateLength > length {
        length = candidateLength
        start = segmentStart
        end = segmentEnd
        runIndex = index
      }
    }
    guard length > 0 else {
      return nil
    }
    // Only a run that turns UP/DOWN into a top/bottom port is a fan-in run: a
    // vertical stub must follow it toward the target. A horizontal run that is
    // itself the final approach into a leading/trailing port is a side entry,
    // where duplicate labels belong on the vertical feeders, not the run - the
    // greedy placer keeps owning that case.
    let stubIndex = runIndex + 1
    guard stubIndex < points.count - 1 else {
      return nil
    }
    let stubStart = points[stubIndex]
    let stubEnd = points[stubIndex + 1]
    guard abs(stubStart.x - stubEnd.x) < 0.5, abs(stubStart.y - stubEnd.y) > 0.5 else {
      return nil
    }
    id = route.id
    size = route.size
    runStart = start
    runEnd = end
  }
}

private func policyCanvasRunsFormTightStack(_ members: [PolicyCanvasFanInLabelMember]) -> Bool {
  let height = members.map(\.size.height).max() ?? PolicyCanvasLayout.edgeLabelHeight
  let maximumGap = height + PolicyCanvasLayout.gridSize
  for index in 1..<members.count {
    let gap = members[index].runY - members[index - 1].runY
    guard gap > 0.5, gap <= maximumGap else {
      return false
    }
    let low = max(members[index].runLow, members[index - 1].runLow)
    let high = min(members[index].runHigh, members[index - 1].runHigh)
    guard high - low >= PolicyCanvasLayout.gridSize * 4 else {
      return false
    }
  }
  return true
}

private func policyCanvasStaircasePlacement(
  _ members: [PolicyCanvasFanInLabelMember],
  nodeFrames: [CGRect],
  edgeFrames: [String: [CGRect]]
) -> [String: CGPoint] {
  let clearance = PolicyCanvasLayout.gridSize
  var windowLow = -CGFloat.greatestFiniteMagnitude
  var windowHigh = CGFloat.greatestFiniteMagnitude
  for member in members {
    windowLow = max(windowLow, member.runLow + member.size.width / 2 + clearance)
    windowHigh = min(windowHigh, member.runHigh - member.size.width / 2 - clearance)
  }
  guard windowHigh - windowLow >= PolicyCanvasLayout.gridSize else {
    return [:]
  }
  let step = min(
    (windowHigh - windowLow) / CGFloat(members.count),
    PolicyCanvasLayout.gridSize * 4
  )
  // Seat the top run nearest the right edge of the window, then step each lower
  // run one notch left. `ceiling` keeps every label strictly left of the one
  // above so the result is a monotonic stair even when a label has to slide to
  // dodge a crossing edge.
  var placed: [String: CGPoint] = [:]
  var occupied: [CGRect] = []
  var ceiling = windowHigh
  for member in members {
    let blockers =
      nodeFrames
      + edgeFrames.filter { $0.key != member.id }.flatMap { $0.value }
      + occupied
    guard
      let x = policyCanvasClearStaircaseX(
        startingFrom: ceiling,
        downTo: windowLow,
        member: member,
        blockers: blockers
      )
    else {
      return placed
    }
    let center = CGPoint(x: x, y: member.runY)
    placed[member.id] = center
    occupied.append(policyCanvasFanInLabelFrame(center: center, size: member.size))
    ceiling = x - step
  }
  return placed
}

private func policyCanvasClearStaircaseX(
  startingFrom ceiling: CGFloat,
  downTo windowLow: CGFloat,
  member: PolicyCanvasFanInLabelMember,
  blockers: [CGRect]
) -> CGFloat? {
  guard ceiling >= windowLow else {
    return nil
  }
  let stride = PolicyCanvasLayout.gridSize / 2
  var x = ceiling
  while x >= windowLow {
    let frame = policyCanvasFanInLabelFrame(
      center: CGPoint(x: x, y: member.runY),
      size: member.size
    )
    if !blockers.contains(where: { $0.intersects(frame) }) {
      return x
    }
    x -= stride
  }
  return nil
}

private func policyCanvasFanInLabelFrame(center: CGPoint, size: CGSize) -> CGRect {
  CGRect(
    x: center.x - (size.width / 2),
    y: center.y - (size.height / 2),
    width: size.width,
    height: size.height
  )
}
