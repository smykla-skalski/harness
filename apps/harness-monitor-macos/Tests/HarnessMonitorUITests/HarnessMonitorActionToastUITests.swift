import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorActionToastUITests: HarnessMonitorUITestCase {
  func testActionToastAppearsAndAutoDismisses() throws {
    let app = launch(mode: "preview")

    tapPreviewSession(in: app)

    let observeButton = app.buttons["Observe"].firstMatch
    XCTAssertTrue(observeButton.waitForExistence(timeout: Self.actionTimeout))
    if observeButton.isHittable {
      observeButton.tap()
    } else if let coordinate = centerCoordinate(in: app, for: observeButton) {
      coordinate.tap()
    } else {
      XCTFail("Failed to tap Observe button")
    }

    let toast = element(in: app, identifier: Accessibility.actionToast)
    XCTAssertTrue(
      toast.waitForExistence(timeout: Self.actionTimeout),
      "Toast should appear after action"
    )

    let dismissed = waitUntil(timeout: 2) { !toast.exists }
    XCTAssertTrue(dismissed, "Toast should dismiss after appearing")
  }
}
