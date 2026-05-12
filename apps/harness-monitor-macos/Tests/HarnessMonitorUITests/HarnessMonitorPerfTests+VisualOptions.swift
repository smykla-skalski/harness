import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension HarnessMonitorPerfTests {
  private static let visualOptionsDisabledScenarios = [
    "open-session-window-visual-options-disabled",
    "agent-detail-form-visual-options-disabled",
    "decision-detail-form-visual-options-disabled",
    "task-detail-form-visual-options-disabled",
    "session-search-full-visual-options-disabled",
    "timeline-filter-form-visual-options-disabled",
  ]

  func testOpenSessionWindowVisualOptionsDisabledHitchRate() {
    measureScenario("open-session-window-visual-options-disabled")
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

  func testVisualOptionsDisabledScenarioPreviewRouting() {
    for scenario in Self.visualOptionsDisabledScenarios {
      let expected = scenario.contains("decision-detail-form") ? "cockpit" : "dashboard-landing"

      XCTAssertEqual(expectedPreviewScenario(for: scenario), expected)
    }
  }

  func expectedPreviewScenario(for scenario: String) -> String {
    let visualOptionsSuffix = "-visual-options-disabled"
    let baseScenario =
      scenario.hasSuffix(visualOptionsSuffix)
      ? String(scenario.dropLast(visualOptionsSuffix.count))
      : scenario

    switch baseScenario {
    case "open-recent-window", "open-session-window",
      "agent-detail-form", "task-detail-form", "session-search-full",
      "timeline-filter-form", "timeline-burst", "toast-overlay-churn":
      return "dashboard-landing"
    case "decision-detail-form", "permission-modal":
      return "cockpit"
    case "offline-cached-open":
      return "offline-cached"
    default:
      return "dashboard"
    }
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
