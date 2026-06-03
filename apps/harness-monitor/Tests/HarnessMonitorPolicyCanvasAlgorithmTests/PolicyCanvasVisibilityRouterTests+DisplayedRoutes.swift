import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

extension PolicyCanvasVisibilityRouterTests {
  @Test("Channel snap rounds intermediate points to 5pt grid")
  func channelSnapAlignsIntermediates() {
    let obstacle = CGRect(x: 100, y: 50, width: 80, height: 120)
    let route = PolicyCanvasVisibilityRouter().route(
      source: CGPoint(x: 0, y: 100),
      target: CGPoint(x: 400, y: 100),
      context: context(lane: 1, obstacles: [obstacle])
    )
    for index in 1..<(route.points.count - 1) {
      let point = route.points[index]
      #expect(point.x.truncatingRemainder(dividingBy: 5) == 0)
      #expect(point.y.truncatingRemainder(dividingBy: 5) == 0)
    }
  }
}
