import XCTest

@testable import HarnessMonitorUIPreviewable

final class SessionWindowCyclerTests: XCTestCase {
  func testForwardAdvancesByOneAndWraps() {
    XCTAssertEqual(
      SessionWindowCycler.nextIndex(currentIndex: 0, count: 3, direction: .forward),
      1
    )
    XCTAssertEqual(
      SessionWindowCycler.nextIndex(currentIndex: 2, count: 3, direction: .forward),
      0
    )
  }

  func testBackwardAdvancesByOneAndWraps() {
    XCTAssertEqual(
      SessionWindowCycler.nextIndex(currentIndex: 1, count: 3, direction: .backward),
      0
    )
    XCTAssertEqual(
      SessionWindowCycler.nextIndex(currentIndex: 0, count: 3, direction: .backward),
      2
    )
  }

  func testSingleCandidateStaysOnIndexZeroInBothDirections() {
    XCTAssertEqual(
      SessionWindowCycler.nextIndex(currentIndex: 0, count: 1, direction: .forward),
      0
    )
    XCTAssertEqual(
      SessionWindowCycler.nextIndex(currentIndex: 0, count: 1, direction: .backward),
      0
    )
  }

  func testNegativeOrOutOfRangeIndexNormalizesBeforeAdvancing() {
    XCTAssertEqual(
      SessionWindowCycler.nextIndex(currentIndex: -1, count: 3, direction: .forward),
      0
    )
    XCTAssertEqual(
      SessionWindowCycler.nextIndex(currentIndex: 5, count: 3, direction: .backward),
      1
    )
  }
}
