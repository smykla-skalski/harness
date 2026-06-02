import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas
@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas route intrinsic score")
struct PolicyCanvasRouteIntrinsicScoreTests {
  @Test("empty route returns greatestFiniteMagnitude")
  func emptyRouteReturnsGreatestFiniteMagnitude() {
    let route = PolicyCanvasEdgeRoute(points: [], labelPosition: .zero)
    let score = policyCanvasRouteIntrinsicScore(route)
    #expect(score == .greatestFiniteMagnitude)
  }

  @Test("single-point route returns greatestFiniteMagnitude")
  func singlePointRouteReturnsGreatestFiniteMagnitude() {
    let route = PolicyCanvasEdgeRoute(points: [.zero], labelPosition: .zero)
    let score = policyCanvasRouteIntrinsicScore(route)
    #expect(score == .greatestFiniteMagnitude)
  }

  @Test("non-empty route returns finite small score")
  func nonEmptyRouteReturnsFiniteSmallScore() {
    let route = PolicyCanvasEdgeRoute(
      points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
      labelPosition: .zero
    )
    let score = policyCanvasRouteIntrinsicScore(route)
    #expect(score < .greatestFiniteMagnitude)
    #expect(score >= 0)
  }
}
