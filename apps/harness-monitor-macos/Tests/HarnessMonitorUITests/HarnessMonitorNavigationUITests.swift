import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorNavigationUITests: HarnessMonitorUITestCase {

  /// Reproduces the reported issue: after selecting a session from the
  /// dashboard, the toolbar back button remains disabled (greyed out)
  /// when it should become enabled so the user can navigate back.
  func testBackButtonEnablesAfterSelectingSession() throws {
    let app = launch(mode: "preview")

    let backButton = toolbarButton(in: app, identifier: Accessibility.navigateBackButton)
    XCTAssertTrue(
      backButton.waitForExistence(timeout: Self.actionTimeout),
      "Back button should exist in toolbar")

    // Before selecting a session the back button must be disabled.
    XCTAssertFalse(
      backButton.isEnabled, "Back button should be disabled with no navigation history")

    // Select the preview session from the sidebar.
    tapPreviewSession(in: app)

    // Wait for the cockpit to load (proves selection completed).
    let observeButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(
      observeButton.waitForExistence(timeout: Self.actionTimeout),
      "Session cockpit should load after selecting preview session"
    )

    // The back button must now be enabled - the dashboard is in the back stack.
    let enabled = waitUntil(timeout: Self.actionTimeout) {
      backButton.isEnabled
    }

    attachWindowScreenshot(in: app, named: "back-button-after-selection")

    XCTAssertTrue(
      enabled,
      "Back button should be enabled after navigating from dashboard to a session"
    )
  }

  /// Verifies that tapping back actually navigates to the previous view
  /// and that forward then becomes enabled.
  func testBackNavigatesToDashboardAndEnablesForward() throws {
    let app = launch(mode: "preview")

    let backButton = toolbarButton(in: app, identifier: Accessibility.navigateBackButton)
    let forwardButton = toolbarButton(in: app, identifier: Accessibility.navigateForwardButton)
    XCTAssertTrue(backButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(forwardButton.waitForExistence(timeout: Self.actionTimeout))

    // Select the preview session.
    tapPreviewSession(in: app)
    let observeButton = app.buttons
      .matching(identifier: Accessibility.observeSummaryButton)
      .firstMatch
    XCTAssertTrue(observeButton.waitForExistence(timeout: Self.actionTimeout))

    // Wait for back to become enabled.
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { backButton.isEnabled },
      "Back button should be enabled after session selection"
    )

    // Tap back.
    backButton.tap()

    // The dashboard should reappear (no session selected -> board shows).
    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    XCTAssertTrue(
      boardRoot.waitForExistence(timeout: Self.actionTimeout),
      "Dashboard should appear after navigating back"
    )

    // Forward should now be enabled, back should be disabled.
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { forwardButton.isEnabled },
      "Forward button should be enabled after going back"
    )
    XCTAssertFalse(backButton.isEnabled, "Back button should be disabled at start of history")
  }
}
