import CoreGraphics
import Foundation
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Policy canvas label route segment axis classification")
struct PolicyCanvasLabelRouteSegmentTests {
  @Test("horizontal segment classifies horizontal")
  func horizontalSegmentClassifiesHorizontal() {
    let segment = PolicyCanvasLabelRouteSegment(
      start: CGPoint(x: 0, y: 50),
      end: CGPoint(x: 100, y: 50)
    )
    #expect(segment?.isHorizontal == true)
    #expect(segment?.isVertical == false)
    #expect(segment?.axis == .horizontal)
  }

  @Test("vertical segment classifies vertical")
  func verticalSegmentClassifiesVertical() {
    let segment = PolicyCanvasLabelRouteSegment(
      start: CGPoint(x: 50, y: 0),
      end: CGPoint(x: 50, y: 100)
    )
    #expect(segment?.isHorizontal == false)
    #expect(segment?.isVertical == true)
    #expect(segment?.axis == .vertical)
  }

  @Test("diagonal segment is neither horizontal nor vertical")
  func diagonalSegmentIsNeitherHorizontalNorVertical() {
    let segment = PolicyCanvasLabelRouteSegment(
      start: CGPoint(x: 0, y: 0),
      end: CGPoint(x: 100, y: 80)
    )
    #expect(segment?.isHorizontal == false, "Diagonal should not be tagged horizontal")
    #expect(segment?.isVertical == false, "Diagonal should not be tagged vertical")
    // Axis falls back to dominant extent (here x=100 > y=80)
    #expect(segment?.axis == .horizontal)
  }

  @Test("diagonal with dominant vertical extent falls back to vertical axis")
  func diagonalDominantVerticalFallsBackToVerticalAxis() {
    let segment = PolicyCanvasLabelRouteSegment(
      start: CGPoint(x: 0, y: 0),
      end: CGPoint(x: 40, y: 200)
    )
    #expect(segment?.isHorizontal == false)
    #expect(segment?.isVertical == false)
    #expect(segment?.axis == .vertical)
  }

  @Test("length is consistent with lengthSquared")
  func lengthConsistentWithLengthSquared() {
    let segment = PolicyCanvasLabelRouteSegment(
      start: CGPoint(x: 0, y: 0),
      end: CGPoint(x: 30, y: 40)
    )
    #expect(segment?.lengthSquared == 2500)
    #expect(segment?.length == 50)
  }
}
