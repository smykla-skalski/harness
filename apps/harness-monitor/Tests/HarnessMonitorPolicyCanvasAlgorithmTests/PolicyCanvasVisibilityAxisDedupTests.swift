import CoreGraphics
import Testing

@testable import HarnessMonitorPolicyCanvasAlgorithms

@Suite("Policy canvas visibility-grid axis dedup")
struct PolicyCanvasVisibilityAxisDedupTests {
  @Test("coordinates that differ by sub-pt amounts collapse to one axis line")
  func subPointDivergenceDedupes() {
    let value: CGFloat = 100.0
    let close: CGFloat = 100.0001
    let axes = PolicyCanvasVisibilityRouter.sortedAxisCoordinates(
      anchor1: value,
      anchor2: 500,
      laneOffset: 0,
      bounds: [(close, 200)],
      corridorStep: 0
    )
    let occurrences = axes.filter { abs($0 - value) < 0.5 }.count
    #expect(occurrences == 1)
  }

  @Test("quantization preserves coordinates that differ by more than a millipoint")
  func quantizationPreservesDistinctCoordinates() {
    let axes = PolicyCanvasVisibilityRouter.sortedAxisCoordinates(
      anchor1: 100,
      anchor2: 500,
      laneOffset: 0,
      bounds: [(100.1, 200)],
      corridorStep: 0
    )
    let occurrences = axes.filter { abs($0 - 100) < 0.05 }.count
    #expect(occurrences == 1)
    let nearOccurrences = axes.filter { abs($0 - 100.1) < 0.05 }.count
    #expect(nearOccurrences == 1)
  }

  @Test("quantizedCoordinate snaps to nearest millipoint")
  func quantizedCoordinateSnaps() {
    #expect(PolicyCanvasVisibilityRouter.quantizedCoordinate(100.0001) == 100.0)
    #expect(PolicyCanvasVisibilityRouter.quantizedCoordinate(100.0006) == 100.001)
  }
}
