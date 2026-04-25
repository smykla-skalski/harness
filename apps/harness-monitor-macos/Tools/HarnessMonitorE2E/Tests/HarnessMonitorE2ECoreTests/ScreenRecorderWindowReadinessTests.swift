import CoreGraphics
import XCTest

@testable import HarnessMonitorE2ECore

@available(macOS 15.0, *)
final class ScreenRecorderWindowReadinessTests: XCTestCase {
  private let displays: [ScreenRecorderDisplayCandidate] = [
    ScreenRecorderDisplayCandidate(
      displayID: 1,
      frame: CGRect(x: 0, y: 0, width: 2056, height: 1329)
    )
  ]

  func testZeroAreaFrameReportsNotReadyWithZeroFrameReason() {
    let result = ScreenRecorderWindowReadiness.evaluate(
      windowFrame: .zero,
      displays: displays
    )
    switch result {
    case .ready:
      XCTFail("Expected notReady for zero-area frame")
    case .notReady(let reason):
      XCTAssertEqual(reason, "zero-frame")
    }
  }

  func testFrameOutsideAllDisplaysReportsNotReadyWithNoDisplayOverlap() {
    let result = ScreenRecorderWindowReadiness.evaluate(
      windowFrame: CGRect(x: 5000, y: 5000, width: 100, height: 100),
      displays: displays
    )
    switch result {
    case .ready:
      XCTFail("Expected notReady for frame outside all displays")
    case .notReady(let reason):
      XCTAssertEqual(reason, "no-display-overlap")
    }
  }

  func testPositiveFrameOverlappingDisplayReportsReady() {
    let result = ScreenRecorderWindowReadiness.evaluate(
      windowFrame: CGRect(x: 100, y: 100, width: 1280, height: 820),
      displays: displays
    )
    switch result {
    case .notReady(let reason):
      XCTFail("Expected ready, got notReady(\(reason))")
    case .ready(let display):
      XCTAssertEqual(display.displayID, 1)
    }
  }
}
