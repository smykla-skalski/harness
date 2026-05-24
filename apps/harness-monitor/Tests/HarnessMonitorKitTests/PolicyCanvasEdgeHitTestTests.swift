import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas edge hit test - fat stroke covers polyline midpoint")
struct PolicyCanvasEdgeHitTestTests {
  @Test("Hit shape covers a point on the polyline")
  func hitShapeCoversOnRoutePoint() {
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 100, y: 0),
        CGPoint(x: 100, y: 100),
      ],
      labelPosition: CGPoint(x: 100, y: 50)
    )
    let path = PolicyCanvasEdgeHitShape(route: route).path(in: .zero)
    // Midpoint of the first segment lies on the route.
    #expect(path.contains(CGPoint(x: 50, y: 0)))
    // Midpoint of the second segment.
    #expect(path.contains(CGPoint(x: 100, y: 50)))
  }

  @Test("Hit shape misses a point far from the polyline")
  func hitShapeMissesFarPoint() {
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 100, y: 0),
        CGPoint(x: 100, y: 100),
      ],
      labelPosition: CGPoint(x: 100, y: 50)
    )
    let path = PolicyCanvasEdgeHitShape(route: route).path(in: .zero)
    // 50pt from the closest segment - well outside the 12pt fat stroke.
    #expect(!path.contains(CGPoint(x: 50, y: 50)))
    #expect(!path.contains(CGPoint(x: 200, y: 200)))
  }

  @Test("Fat hit area widens the hit zone to roughly 12pt")
  func hitShapeWidthIsApproximatelyTwelvePoints() {
    let route = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
      labelPosition: CGPoint(x: 50, y: 0)
    )
    let path = PolicyCanvasEdgeHitShape(route: route).path(in: .zero)
    // ±5pt above/below the line should still hit (half of 12 minus padding).
    #expect(path.contains(CGPoint(x: 50, y: 5)))
    #expect(path.contains(CGPoint(x: 50, y: -5)))
    // ±7pt is outside the fat stroke.
    #expect(!path.contains(CGPoint(x: 50, y: 8)))
    #expect(!path.contains(CGPoint(x: 50, y: -8)))
  }
}
