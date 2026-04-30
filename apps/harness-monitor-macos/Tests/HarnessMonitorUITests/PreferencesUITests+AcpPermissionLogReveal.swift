import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class PreferencesUITests_AcpPermissionLogReveal: HarnessMonitorUITestCase {
  func testDiagnosticsShowsPermissionLogRevealButtonForActiveRun() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: ["HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1"]
    )

    openSettings(in: app)
    selectPreferencesSection(
      in: app,
      identifier: Accessibility.preferencesDiagnosticsSection,
      expectedTitle: "Diagnostics"
    )

    let revealButton = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@",
        "harness.preferences.diagnostics.acp-permission-log.reveal."
      )
    ).firstMatch
    XCTAssertTrue(
      waitForElement(revealButton, timeout: Self.uiTimeout),
      "Diagnostics should surface a reveal-permission-log button for active ACP runs"
    )
  }

  func testDiagnosticsShowsInlineErrorWhenPermissionLogPathIsMissing() throws {
    let app = launchInCockpitPreview(
      additionalEnvironment: [
        "HARNESS_MONITOR_PREVIEW_ACP_PENDING": "1",
        "HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_LOG_PATH": "",
      ]
    )

    openSettings(in: app)
    selectPreferencesSection(
      in: app,
      identifier: Accessibility.preferencesDiagnosticsSection,
      expectedTitle: "Diagnostics"
    )

    let revealButton = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@",
        "harness.preferences.diagnostics.acp-permission-log.reveal."
      )
    ).firstMatch
    XCTAssertTrue(waitForElement(revealButton, timeout: Self.uiTimeout))
    revealButton.tap()

    let inlineError = app.staticTexts["ACP permission log for this run is unavailable."]
    XCTAssertTrue(
      waitForElement(inlineError, timeout: Self.uiTimeout),
      "Diagnostics should show inline error when permission log path is missing"
    )
  }
}
