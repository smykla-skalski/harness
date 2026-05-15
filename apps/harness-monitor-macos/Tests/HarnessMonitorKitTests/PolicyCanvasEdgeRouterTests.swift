import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas edge router protocol")
struct PolicyCanvasEdgeRouterTests {
  @Test("Hand-coded router default produces same polyline as direct init")
  func handCodedRouterBitIdenticalToDirectInit() {
    let router = PolicyCanvasHandCodedOrthogonalRouter()
    let viaRouter = router.route(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 100),
      lane: 0,
      groups: [],
      sourceGroupID: nil,
      targetGroupID: nil
    )
    let direct = PolicyCanvasEdgeRoute(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 100),
      lane: 0
    )
    #expect(viaRouter.points == direct.points)
    #expect(viaRouter.labelPosition == direct.labelPosition)
  }

  @Test("Lane parameter spreads parallel routes the same way as direct init")
  func handCodedRouterLaneSpread() {
    let router = PolicyCanvasHandCodedOrthogonalRouter()
    let lane0 = router.route(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 100),
      lane: 0,
      groups: [],
      sourceGroupID: nil,
      targetGroupID: nil
    )
    let lane3 = router.route(
      source: CGPoint(x: 0, y: 0),
      target: CGPoint(x: 200, y: 100),
      lane: 3,
      groups: [],
      sourceGroupID: nil,
      targetGroupID: nil
    )
    #expect(lane0.points[1].x != lane3.points[1].x)
  }
}
