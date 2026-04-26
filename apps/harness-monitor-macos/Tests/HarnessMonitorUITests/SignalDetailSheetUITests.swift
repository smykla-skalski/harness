import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class SignalDetailSheetUITests: HarnessMonitorUITestCase {
  func testCockpitOpensSheet() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_FIXTURE_SET": "signal-regression"]
    )

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let signalCard = button(in: app, identifier: Accessibility.previewSignalCard)
    XCTAssertTrue(
      signalCard.waitForExistence(timeout: Self.uiTimeout),
      "Cockpit signal card should render in cockpit preview"
    )
    tapButton(in: app, identifier: Accessibility.previewSignalCard)

    let sheet = element(in: app, identifier: Accessibility.signalDetailSheet)
    XCTAssertTrue(
      sheet.waitForExistence(timeout: Self.actionTimeout),
      "Signal detail sheet should appear after tapping the cockpit signal card"
    )

    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { !sheet.exists },
      "Sheet should dismiss on Escape"
    )
  }
}
