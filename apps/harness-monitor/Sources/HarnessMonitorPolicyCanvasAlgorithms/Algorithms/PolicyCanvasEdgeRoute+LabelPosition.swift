// Label-position and segment helpers extracted from PolicyCanvasEdgeRoute to
// satisfy file-length and type-body-length limits.
import SwiftUI

extension PolicyCanvasEdgeRoute {
  static func labelPosition(for points: [CGPoint], lane: Int) -> CGPoint {
    let segments = zip(points, points.dropFirst())
    let preferred =
      segments
      .filter { left, right in
        abs(right.x - left.x) >= abs(right.y - left.y)
      }
      .max { left, right in
        segmentLength(left) < segmentLength(right)
      }
    let segment =
      preferred
      ?? zip(points, points.dropFirst()).max { left, right in
        segmentLength(left) < segmentLength(right)
      }
    guard let segment else {
      return points.first ?? .zero
    }
    let horizontal = abs(segment.1.x - segment.0.x) >= abs(segment.1.y - segment.0.y)
    let laneT = min(0.78, max(0.22, 0.38 + CGFloat(lane % 6) * 0.07))
    let positionFraction = horizontal ? laneT : 0.5
    return CGPoint(
      x: segment.0.x + ((segment.1.x - segment.0.x) * positionFraction),
      y: segment.0.y + ((segment.1.y - segment.0.y) * positionFraction)
    ).snappedToPolicyCanvasRouteGrid()
  }

  static func segmentLength(_ segment: (CGPoint, CGPoint)) -> CGFloat {
    hypot(segment.1.x - segment.0.x, segment.1.y - segment.0.y)
  }
}

extension CGPoint {
  func snappedToPolicyCanvasRouteGrid() -> CGPoint {
    CGPoint(
      x: PolicyCanvasLayout.routeGridRound(x),
      y: PolicyCanvasLayout.routeGridRound(y)
    )
  }
}
