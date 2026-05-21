import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
class HarnessMonitorNavigationUITests: HarnessMonitorUITestCase {
  override nonisolated class var reuseLaunchedApp: Bool { true }

  /// Reproduces the reported issue: after selecting a session from the
  /// dashboard, the newly focused session window must inherit the shared
  /// history stack so its toolbar back button becomes enabled.
  func testBackButtonEnablesAfterSelectingSession() throws {
    let app = launch(mode: "preview")

    let dashboardBackButton = toolbarButton(in: app, identifier: Accessibility.navigateBackButton)
    XCTAssertTrue(
      dashboardBackButton.waitForExistence(timeout: Self.actionTimeout),
      "Back button should exist in dashboard toolbar")

    // Before selecting a session the back button must be disabled.
    XCTAssertFalse(
      dashboardBackButton.isEnabled,
      "Dashboard back button should be disabled with no navigation history"
    )

    // Select the preview session from the sidebar.
    tapPreviewSession(in: app)

    let sessionWindow = element(in: app, identifier: Accessibility.sessionWindowShell)
    XCTAssertTrue(
      sessionWindow.waitForExistence(timeout: Self.actionTimeout),
      "Session window should appear after selecting a session from the dashboard"
    )
    let sessionBackButton = toolbarButton(
      in: app,
      identifier: Accessibility.sessionNavigateBackButton
    )
    XCTAssertTrue(
      sessionBackButton.waitForExistence(timeout: Self.actionTimeout),
      "Session history button should appear in the session toolbar"
    )

    // The session back button must now be enabled - the dashboard is in the
    // shared cross-window back stack.
    let enabled = waitUntil(timeout: Self.actionTimeout) {
      sessionBackButton.isEnabled
    }

    attachWindowScreenshot(in: app, named: "back-button-after-selection")

    XCTAssertTrue(
      enabled,
      "Session back button should be enabled after navigating from dashboard to a session"
    )
  }

  /// Verifies that global history can move focus back to the dashboard window
  /// and that the dashboard forward button then reopens the session entry.
  func testBackNavigatesToDashboardAndEnablesForward() throws {
    let app = launch(mode: "preview")

    let dashboardBackButton = toolbarButton(in: app, identifier: Accessibility.navigateBackButton)
    let dashboardForwardButton = toolbarButton(in: app, identifier: Accessibility.navigateForwardButton)
    XCTAssertTrue(dashboardBackButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(dashboardForwardButton.waitForExistence(timeout: Self.actionTimeout))

    // Select the preview session.
    tapPreviewSession(in: app)
    let sessionWindow = element(in: app, identifier: Accessibility.sessionWindowShell)
    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.actionTimeout))
    let sessionBackButton = toolbarButton(
      in: app,
      identifier: Accessibility.sessionNavigateBackButton
    )
    let sessionForwardButton = toolbarButton(
      in: app,
      identifier: Accessibility.sessionNavigateForwardButton
    )
    XCTAssertTrue(sessionBackButton.waitForExistence(timeout: Self.actionTimeout))
    XCTAssertTrue(sessionForwardButton.waitForExistence(timeout: Self.actionTimeout))

    // Wait for the session-window back button to become enabled.
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { sessionBackButton.isEnabled },
      "Session back button should be enabled after session selection"
    )

    // Tap back on the session window; global history should return focus to the
    // dashboard window and enable forward there.
    XCTAssertTrue(
      tapElementReliably(in: app, element: sessionBackButton),
      "Session back button should be tappable"
    )

    let dashboardWindow = element(in: app, identifier: Accessibility.dashboardWindowRoot)
    let boardRoot = element(in: app, identifier: Accessibility.sessionsBoardRoot)
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        dashboardWindow.exists && boardRoot.exists
      },
      "Dashboard should appear after navigating back across windows"
    )

    // Forward should now be enabled on the dashboard, while the dashboard back
    // button stays disabled at the start of the stack.
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) { dashboardForwardButton.isEnabled },
      "Dashboard forward button should be enabled after going back"
    )
    XCTAssertFalse(
      dashboardBackButton.isEnabled,
      "Dashboard back button should be disabled at the start of history"
    )
  }

}
