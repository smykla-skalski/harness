import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class LeaderTransferSheetUITests: HarnessMonitorUITestCase {
  func testHeaderButtonOpens() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let openButton = button(in: app, identifier: Accessibility.leaderTransferOpenButton)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        openButton.exists && !openButton.frame.isEmpty
      },
      "Cockpit header should expose a Transfer Leadership button when multiple agents exist"
    )
    tapElement(in: app, identifier: Accessibility.leaderTransferOpenButton)

    let sheet = element(in: app, identifier: Accessibility.leaderTransferSheet)
    XCTAssertTrue(
      sheet.waitForExistence(timeout: Self.actionTimeout),
      "Leader transfer sheet should appear after tapping the header button"
    )

    let picker = element(in: app, identifier: Accessibility.leaderTransferPicker)
    XCTAssertTrue(
      picker.waitForExistence(timeout: Self.actionTimeout),
      "Leader transfer sheet should expose the new leader picker"
    )

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !sheet.exists },
      "Sheet should dismiss on Escape"
    )
  }
}
