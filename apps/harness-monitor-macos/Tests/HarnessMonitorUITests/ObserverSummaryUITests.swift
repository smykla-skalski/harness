import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class ObserverSummaryUITests: HarnessMonitorUITestCase {
  func testCockpitFocusesDecisionsObserver() throws {
    let app = launch(
      mode: "preview",
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_SCENARIO": "cockpit"]
    )

    let sessionRow = previewSessionTrigger(in: app)
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.actionTimeout))
    tapPreviewSession(in: app)

    let summaryCard = element(in: app, identifier: "harness.session.observe.summary")
    XCTAssertTrue(
      summaryCard.waitForExistence(timeout: Self.actionTimeout),
      "Observer summary card should render in cockpit preview"
    )
    tapElement(in: app, identifier: "harness.session.observe.summary")

    let decisionsWindow = element(in: app, identifier: Accessibility.decisionsWindow)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { decisionsWindow.exists },
      "Decisions window should open after tapping the cockpit observer summary"
    )

    let observerPanel = element(in: app, identifier: Accessibility.decisionsObserverPanel)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { observerPanel.exists },
      "Observer summary panel should render in the decisions window after focus"
    )
  }
}
