import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas labelPosition fallback")
struct PolicyCanvasLabelPositionTests {
  @Test("pure-vertical route centers the label on the collapsed vertical run")
  func pureVerticalPicksLongestVerticalSegment() {
    // Three collinear vertical points: a 10-unit stub (0, 0) -> (0, 10) then
    // (0, 10) -> (0, 100). Collinear points collapse before the segment pick, so
    // the route is one (0, 0) -> (0, 100) run and the label centers on it at
    // y = 50 - the true center of the visible line, not the midpoint of a stub.
    let points: [CGPoint] = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 0, y: 10),
      CGPoint(x: 0, y: 100),
    ]
    let position = PolicyCanvasVisibilityRouter.labelPosition(for: points)
    #expect(position.x == 0)
    #expect(position.y == 50, "Expected center of the collapsed (0,0)-(0,100) run, got y=\(position.y)")
  }

  @Test("horizontal-dominant route still picks longest horizontal segment")
  func horizontalDominantRoutePicksLongestHorizontal() {
    // (0,0) -> (200,0) horizontal length 200, (200,0) -> (200,50) vertical,
    // (200,50) -> (250,50) horizontal length 50. Pick the long horizontal.
    let points: [CGPoint] = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 200, y: 0),
      CGPoint(x: 200, y: 50),
      CGPoint(x: 250, y: 50),
    ]
    let position = PolicyCanvasVisibilityRouter.labelPosition(for: points)
    #expect(position.x == 100)
    #expect(position.y == 0)
  }

  @Test("mixed route with longer vertical still prefers horizontal segment")
  func mixedRoutePrefersHorizontalEvenWhenVerticalLonger() {
    // Horizontal 40 vs vertical 200 -- the function intentionally prefers
    // horizontal so labels read along the bus, not the riser.
    let points: [CGPoint] = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 40, y: 0),
      CGPoint(x: 40, y: 200),
    ]
    let position = PolicyCanvasVisibilityRouter.labelPosition(for: points)
    #expect(position.x == 20)
    #expect(position.y == 0)
  }
}
