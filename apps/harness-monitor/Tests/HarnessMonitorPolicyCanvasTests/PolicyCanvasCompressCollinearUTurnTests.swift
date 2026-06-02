import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorPolicyCanvas

@Suite("Policy canvas compressCollinear U-turn cleanup")
struct PolicyCanvasCompressCollinearUTurnTests {
  @Test("horizontal same-direction collinear collapses")
  func horizontalSameDirectionCollapses() {
    let result = PolicyCanvasVisibilityRouter.compressCollinear([
      CGPoint(x: 0, y: 0),
      CGPoint(x: 50, y: 0),
      CGPoint(x: 100, y: 0),
    ])
    #expect(result == [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
  }

  @Test("horizontal U-turn collapses midpoint")
  func horizontalUTurnCollapsesMidpoint() {
    let result = PolicyCanvasVisibilityRouter.compressCollinear([
      CGPoint(x: 0, y: 0),
      CGPoint(x: 100, y: 0),
      CGPoint(x: 50, y: 0),
    ])
    #expect(result == [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 0)])
  }

  @Test("vertical same-direction collinear collapses")
  func verticalSameDirectionCollapses() {
    let result = PolicyCanvasVisibilityRouter.compressCollinear([
      CGPoint(x: 0, y: 0),
      CGPoint(x: 0, y: 50),
      CGPoint(x: 0, y: 100),
    ])
    #expect(result == [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100)])
  }

  @Test("vertical U-turn collapses midpoint")
  func verticalUTurnCollapsesMidpoint() {
    let result = PolicyCanvasVisibilityRouter.compressCollinear([
      CGPoint(x: 0, y: 0),
      CGPoint(x: 0, y: 100),
      CGPoint(x: 0, y: 50),
    ])
    #expect(result == [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 50)])
  }

  @Test("chained horizontal reversals collapse to final endpoint")
  func chainedHorizontalReversalsCollapseToFinalEndpoint() {
    let result = PolicyCanvasVisibilityRouter.compressCollinear([
      CGPoint(x: 0, y: 0),
      CGPoint(x: 100, y: 0),
      CGPoint(x: 50, y: 0),
      CGPoint(x: 150, y: 0),
    ])
    #expect(result == [CGPoint(x: 0, y: 0), CGPoint(x: 150, y: 0)])
  }
}
