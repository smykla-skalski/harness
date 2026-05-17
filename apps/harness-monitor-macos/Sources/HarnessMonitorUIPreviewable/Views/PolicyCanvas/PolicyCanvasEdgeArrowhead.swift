import SwiftUI

/// Solid triangle at the route's last point, oriented along the final
/// segment. 9pt long × 7pt wide (3.5pt half-width) - Graphviz-default
/// proportions tuned to read at 0.5x-2x zoom without overshooting the
/// target node.
struct PolicyCanvasEdgeArrowhead: Shape {
  let route: PolicyCanvasEdgeRoute
  var length: CGFloat = 9
  var halfWidth: CGFloat = 3.5

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let points = route.points
    guard points.count >= 2, let tip = points.last else {
      return path
    }
    let previous = points[points.count - 2]
    let direction = (tip - previous).normalized
    guard direction.length > 0 else {
      return path
    }
    let perpendicular = CGPoint(x: -direction.y, y: direction.x)
    let base = tip - direction * length
    let left = base + perpendicular * halfWidth
    let right = base - perpendicular * halfWidth
    path.move(to: tip)
    path.addLine(to: left)
    path.addLine(to: right)
    path.closeSubpath()
    return path
  }
}

func policyCanvasEndpointTrimmedRoute(
  _ route: PolicyCanvasEdgeRoute,
  endpointInset: CGFloat
) -> PolicyCanvasEdgeRoute {
  let startTrimmed = policyCanvasTrimStart(route.points, inset: endpointInset)
  let endTrimmed = policyCanvasTrimStart(Array(startTrimmed.reversed()), inset: endpointInset)
    .reversed()
  return PolicyCanvasEdgeRoute(points: Array(endTrimmed), labelPosition: route.labelPosition)
}

private func policyCanvasTrimStart(
  _ points: [CGPoint],
  inset: CGFloat
) -> [CGPoint] {
  guard inset > 0, points.count > 1 else {
    return points
  }
  var remaining = inset
  var trimmed = points
  while trimmed.count > 1, remaining > 0 {
    let start = trimmed[0]
    let next = trimmed[1]
    let vector = next - start
    let length = vector.length
    guard length > 0.001 else {
      trimmed.removeFirst()
      continue
    }
    if remaining < length {
      trimmed[0] = start + vector.normalized * remaining
      return trimmed
    }
    remaining -= length
    trimmed.removeFirst()
  }
  return trimmed
}
