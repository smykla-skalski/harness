import SwiftUI
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas lane spread")
struct PolicyCanvasLaneSpreadTests {
  @Test("lane 0 leaves the polyline unchanged")
  func laneZeroIsIdentity() {
    let points: [CGPoint] = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 50, y: 0),
      CGPoint(x: 50, y: 100),
      CGPoint(x: 300, y: 100),
      CGPoint(x: 300, y: 200),
      CGPoint(x: 350, y: 200),
    ]
    let spread = PolicyCanvasVisibilityRouter.applyLaneSpread(
      points,
      lane: 0,
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 200),
      lineSpacing: PolicyCanvasLayout.defaultEdgeLineSpacing
    )
    #expect(spread == points)
  }

  @Test("lane > 0 shifts the dominant horizontal interior bus perpendicular")
  func laneOneShiftsHorizontalBus() {
    let points: [CGPoint] = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 50, y: 0),
      CGPoint(x: 50, y: 100),
      CGPoint(x: 300, y: 100),
      CGPoint(x: 300, y: 200),
      CGPoint(x: 350, y: 200),
    ]
    let spread = PolicyCanvasVisibilityRouter.applyLaneSpread(
      points,
      lane: 1,
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 200),
      lineSpacing: PolicyCanvasLayout.defaultEdgeLineSpacing
    )
    #expect(spread.count == points.count)
    #expect(spread.first == points.first)
    #expect(spread.last == points.last)
    #expect(spread[2].y != points[2].y)
    #expect(spread[3].y != points[3].y)
    #expect(spread[2].y == spread[3].y)
    #expect(
      abs(spread[2].y - points[2].y) >= PolicyCanvasLayout.defaultEdgeLineSpacing - 0.001
    )
  }

  @Test("lane 1 and lane 2 produce different signed offsets")
  func adjacentLanesHaveOppositeSign() {
    let points: [CGPoint] = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 50, y: 0),
      CGPoint(x: 50, y: 100),
      CGPoint(x: 300, y: 100),
      CGPoint(x: 300, y: 200),
      CGPoint(x: 350, y: 200),
    ]
    let spread1 = PolicyCanvasVisibilityRouter.applyLaneSpread(
      points,
      lane: 1,
      source: .zero,
      target: .zero,
      lineSpacing: PolicyCanvasLayout.defaultEdgeLineSpacing
    )
    let spread2 = PolicyCanvasVisibilityRouter.applyLaneSpread(
      points,
      lane: 2,
      source: .zero,
      target: .zero,
      lineSpacing: PolicyCanvasLayout.defaultEdgeLineSpacing
    )
    let delta1 = spread1[2].y - points[2].y
    let delta2 = spread2[2].y - points[2].y
    #expect(delta1 != 0)
    #expect(delta2 != 0)
    #expect(delta1.sign != delta2.sign)
    #expect(abs(delta1) >= PolicyCanvasLayout.defaultEdgeLineSpacing - 0.001)
    #expect(abs(delta2) >= PolicyCanvasLayout.defaultEdgeLineSpacing - 0.001)
  }

  @Test("vertical dominant bus shifts on x axis")
  func verticalBusShiftsOnXAxis() {
    let points: [CGPoint] = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 0, y: 50),
      CGPoint(x: 100, y: 50),
      CGPoint(x: 100, y: 200),
      CGPoint(x: 200, y: 200),
      CGPoint(x: 200, y: 250),
    ]
    let spread = PolicyCanvasVisibilityRouter.applyLaneSpread(
      points,
      lane: 1,
      source: .zero,
      target: CGPoint(x: 200, y: 250),
      lineSpacing: PolicyCanvasLayout.defaultEdgeLineSpacing
    )
    #expect(spread[2].x != points[2].x)
    #expect(spread[3].x != points[3].x)
    #expect(spread[2].x == spread[3].x)
    #expect(spread[2].y == points[2].y)
    #expect(spread[3].y == points[3].y)
    #expect(
      abs(spread[2].x - points[2].x) >= PolicyCanvasLayout.defaultEdgeLineSpacing - 0.001
    )
  }
}
