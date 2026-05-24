import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class MainWindowKeyboardParityUITests: HarnessMonitorUITestCase {
  func testOpeningCockpitKeepsSidebarArrowNavigationActive() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "paged-timeline"]
    )

    let primarySessionRow = sessionTrigger(
      in: app,
      identifier: Accessibility.previewSessionRow
    )
    let secondarySessionRow = sessionTrigger(
      in: app,
      identifier: Accessibility.sessionRow("sess5678")
    )
    XCTAssertTrue(waitForElement(primarySessionRow, timeout: Self.actionTimeout))
    XCTAssertTrue(waitForElement(secondarySessionRow, timeout: Self.actionTimeout))
    XCTAssertTrue(self.sessionRowIsSelected(primarySessionRow))

    tapSession(in: app, identifier: Accessibility.sessionRow("sess5678"))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.sessionRowIsSelected(secondarySessionRow)
      }
    )

    tapSession(in: app, identifier: Accessibility.previewSessionRow)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.sessionRowIsSelected(primarySessionRow)
      }
    )

    app.typeKey(.upArrow, modifierFlags: [])

    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        self.sessionRowIsSelected(secondarySessionRow)
      },
      """
      Opening the cockpit must not steal sidebar keyboard navigation.
      primary=\(String(describing: primarySessionRow.value))
      secondary=\(String(describing: secondarySessionRow.value))
      """
    )
  }

}
