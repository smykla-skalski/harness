import XCTest

@MainActor
final class HarnessMonitorUITests: XCTestCase {
  private enum Accessibility {
    static let preferencesButton = "monitor.toolbar.preferences"
    static let previewSessionRow = "monitor.sidebar.session.sess-monitor"
  }

  private static let launchModeKey = "HARNESS_MONITOR_LAUNCH_MODE"

  override func setUpWithError() throws {
    continueAfterFailure = false
  }

  func testPreviewModeLoadsDashboardAndOpensCockpit() throws {
    let app = launch(mode: "preview")

    let daemonLabelExists = app.staticTexts["Harness Daemon"].waitForExistence(timeout: 5)
    XCTAssertTrue(daemonLabelExists)

    let sessionRow = app.buttons.matching(identifier: Accessibility.previewSessionRow).firstMatch
    let sessionRowExists = sessionRow.waitForExistence(timeout: 5)
    XCTAssertTrue(sessionRowExists)

    sessionRow.tap()

    let tasksExists = app.staticTexts["Tasks"].waitForExistence(timeout: 5)
    let signalsExists = app.staticTexts["Signals"].waitForExistence(timeout: 5)
    XCTAssertTrue(tasksExists)
    XCTAssertTrue(signalsExists)
  }

  func testEmptyModeShowsOnboardingCard() throws {
    let app = launch(mode: "empty")

    let onboardingTitleExists = app.staticTexts["Bring The Monitor Online"]
      .waitForExistence(timeout: 5)
    XCTAssertTrue(onboardingTitleExists)
    XCTAssertTrue(app.buttons["Start Daemon"].exists)
  }

  func testToolbarOpensPreferencesSheet() throws {
    let app = launch(mode: "preview")

    let preferencesButton = app.toolbars
      .buttons
      .matching(identifier: Accessibility.preferencesButton)
      .firstMatch
    let preferencesButtonExists = preferencesButton.waitForExistence(timeout: 5)
    XCTAssertTrue(preferencesButtonExists)

    preferencesButton.tap()

    let preferencesTitleExists = app.staticTexts["Daemon Preferences"]
      .waitForExistence(timeout: 5)
    XCTAssertTrue(preferencesTitleExists)
  }

  private func launch(mode: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment[Self.launchModeKey] = mode
    app.launch()
    let windowExists = app.windows.element(boundBy: 0).waitForExistence(timeout: 5)
    XCTAssertTrue(windowExists)
    return app
  }
}
