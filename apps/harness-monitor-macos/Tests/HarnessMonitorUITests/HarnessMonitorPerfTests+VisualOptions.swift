import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension HarnessMonitorPerfTests {
  private static let visualOptionsDisabledScenarios =
    HarnessMonitorUITestPerfScenarioCatalog.visualOptionsDisabledScenarios

  func testOpenSessionWindowVisualOptionsDisabledHitchRate() {
    measureScenario("open-session-window-visual-options-disabled")
  }

  func testSidebarToggleRichDetailVisualOptionsDisabledHitchRate() {
    measureScenario("sidebar-toggle-rich-detail-visual-options-disabled")
  }

  func testOpenSessionWindowVisualOptionsDisabledScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(
      app: app,
      scenario: "open-session-window-visual-options-disabled"
    )
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)

    waitForScenarioCompletion(
      app: launched,
      scenario: "open-session-window-visual-options-disabled"
    )

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    assertPerfVisualOptionsDisabled(
      in: launched,
      scenario: "open-session-window-visual-options-disabled"
    )

    launched.terminate()
  }

  func testSidebarToggleRichDetailVisualOptionsDisabledScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(
      app: app,
      scenario: "sidebar-toggle-rich-detail-visual-options-disabled"
    )
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let timelineFilterBar = element(
      in: launched,
      identifier: Accessibility.sessionTimelineFilterBar
    )

    waitForScenarioCompletion(
      app: launched,
      scenario: "sidebar-toggle-rich-detail-visual-options-disabled"
    )

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(waitForElement(timelineFilterBar, timeout: Self.uiTimeout))
    assertPerfVisualOptionsDisabled(
      in: launched,
      scenario: "sidebar-toggle-rich-detail-visual-options-disabled"
    )

    launched.terminate()
  }

  func testVisualOptionsDisabledScenarioPreviewRouting() {
    for scenario in Self.visualOptionsDisabledScenarios {
      let expected = scenario.contains("decision-detail-form") ? "cockpit" : "dashboard-landing"

      XCTAssertEqual(expectedPreviewScenario(for: scenario), expected)
    }
  }

  func expectedPreviewScenario(for scenario: String) -> String {
    HarnessMonitorUITestPerfScenarioCatalog.expectedPreviewScenario(for: scenario)
  }

  private func assertPerfVisualOptionsDisabled(
    in app: XCUIApplication,
    scenario: String
  ) {
    let perfState = element(in: app, identifier: Accessibility.perfScenarioState)
    XCTAssertTrue(perfState.waitForExistence(timeout: Self.actionTimeout))
    let stateText = text(from: perfState)
    XCTAssertTrue(
      stateText.contains("scenario=\(scenario)"),
      "Perf marker should include scenario \(scenario); got \(stateText)"
    )
    XCTAssertTrue(stateText.contains("backdrop=none"))
    XCTAssertTrue(stateText.contains("shortcutOverlays=disabled"))
    XCTAssertTrue(stateText.contains("titleBlur=disabled"))
    XCTAssertTrue(stateText.contains("menuBarStateColors=disabled"))
  }

  private func text(from element: XCUIElement) -> String {
    if !element.label.isEmpty {
      return element.label
    }

    if let value = element.value as? String, !value.isEmpty {
      return value
    }

    return element.debugDescription
  }
}
