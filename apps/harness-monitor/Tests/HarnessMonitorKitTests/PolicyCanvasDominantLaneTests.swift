import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas dominant lane scope")
struct PolicyCanvasDominantLaneTests {
  @Test("horizontal bus at first segment is captured (4-point route)")
  func horizontalBusAtFirstSegmentCaptured() {
    // (0,0) -> (190,0) horizontal bus, then vertical riser, then (200,100)
    // stub. The horizontal bus at y=0 is the dominant horizontal segment.
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 190, y: 0),
        CGPoint(x: 190, y: 100),
        CGPoint(x: 200, y: 100),
      ],
      labelPosition: .zero
    )
    let y = policyCanvasDominantHorizontalLaneCoordinate(route)
    #expect(y == 0, "Expected dominant horizontal at y=0, got \(String(describing: y))")
  }

  @Test("horizontal bus at last segment is captured (4-point route)")
  func horizontalBusAtLastSegmentCaptured() {
    // (0,0) stub, vertical, then horizontal bus at y=100 length 190
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 10, y: 0),
        CGPoint(x: 10, y: 100),
        CGPoint(x: 200, y: 100),
      ],
      labelPosition: .zero
    )
    let y = policyCanvasDominantHorizontalLaneCoordinate(route)
    #expect(y == 100, "Expected dominant horizontal at y=100, got \(String(describing: y))")
  }

  @Test("middle horizontal bus still captured (regression)")
  func middleHorizontalBusStillCaptured() {
    // Classic Z-shape with bus in the middle
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 0, y: 50),
        CGPoint(x: 200, y: 50),
        CGPoint(x: 200, y: 100),
      ],
      labelPosition: .zero
    )
    let y = policyCanvasDominantHorizontalLaneCoordinate(route)
    #expect(y == 50, "Expected dominant horizontal at y=50, got \(String(describing: y))")
  }

  @Test("vertical bus at first segment is captured (4-point route)")
  func verticalBusAtFirstSegmentCaptured() {
    // (0,0) -> (0,190) vertical bus, horizontal stub, vertical stub
    let route = PolicyCanvasEdgeRoute(
      points: [
        CGPoint(x: 0, y: 0),
        CGPoint(x: 0, y: 190),
        CGPoint(x: 100, y: 190),
        CGPoint(x: 100, y: 200),
      ],
      labelPosition: .zero
    )
    let x = policyCanvasDominantVerticalLaneCoordinate(route)
    #expect(x == 0, "Expected dominant vertical at x=0, got \(String(describing: x))")
  }
}
