import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas compressCollinear U-turn preservation")
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

  @Test("horizontal U-turn preserves midpoint")
  func horizontalUTurnPreservesMidpoint() {
    // Go right to (100, 0) then back to (50, 0) -- a U-turn at index 1.
    // Compression must NOT collapse this into a straight line; the midpoint
    // is load-bearing for scoring the artifact.
    let result = PolicyCanvasVisibilityRouter.compressCollinear([
      CGPoint(x: 0, y: 0),
      CGPoint(x: 100, y: 0),
      CGPoint(x: 50, y: 0),
    ])
    #expect(result.count == 3, "Expected midpoint preserved, got \(result)")
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

  @Test("vertical U-turn preserves midpoint")
  func verticalUTurnPreservesMidpoint() {
    let result = PolicyCanvasVisibilityRouter.compressCollinear([
      CGPoint(x: 0, y: 0),
      CGPoint(x: 0, y: 100),
      CGPoint(x: 0, y: 50),
    ])
    #expect(result.count == 3, "Expected midpoint preserved, got \(result)")
  }
}
