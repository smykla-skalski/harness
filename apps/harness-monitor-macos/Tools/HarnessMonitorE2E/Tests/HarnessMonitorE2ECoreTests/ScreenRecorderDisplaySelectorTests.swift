import CoreGraphics
import XCTest

@testable import HarnessMonitorE2ECore

@available(macOS 15.0, *)
final class ScreenRecorderDisplaySelectorTests: XCTestCase {
  func testCaptureDisplaySelectsContainingDisplay() throws {
    let selected = try ScreenRecorderDisplaySelector.display(
      forWindowFrame: CGRect(x: 120, y: 140, width: 800, height: 500),
      from: [
        ScreenRecorderDisplayCandidate(
          displayID: 1,
          frame: CGRect(x: 0, y: 0, width: 1280, height: 800)
        ),
        ScreenRecorderDisplayCandidate(
          displayID: 2,
          frame: CGRect(x: 1280, y: 0, width: 1440, height: 900)
        ),
      ]
    )

    XCTAssertEqual(selected.displayID, 1)
  }

  func testCaptureDisplaySelectsDisplayWithLargestIntersection() throws {
    let selected = try ScreenRecorderDisplaySelector.display(
      forWindowFrame: CGRect(x: 1000, y: 100, width: 700, height: 500),
      from: [
        ScreenRecorderDisplayCandidate(
          displayID: 1,
          frame: CGRect(x: 0, y: 0, width: 1280, height: 800)
        ),
        ScreenRecorderDisplayCandidate(
          displayID: 2,
          frame: CGRect(x: 1280, y: 0, width: 1440, height: 900)
        ),
      ]
    )

    XCTAssertEqual(selected.displayID, 2)
  }

  func testCaptureDisplayFailsWhenWindowIsOutsideShareableDisplays() {
    XCTAssertThrowsError(
      try ScreenRecorderDisplaySelector.display(
        forWindowFrame: CGRect(x: 3000, y: 3000, width: 400, height: 300),
        from: [
          ScreenRecorderDisplayCandidate(
            displayID: 1,
            frame: CGRect(x: 0, y: 0, width: 1280, height: 800)
          )
        ]
      )
    ) { error in
      XCTAssertEqual(error as? ScreenRecorder.Failure, .monitorDisplayNotFound)
    }
  }
}
