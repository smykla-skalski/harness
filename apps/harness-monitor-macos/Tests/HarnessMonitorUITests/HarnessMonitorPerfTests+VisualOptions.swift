import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension HarnessMonitorPerfTests {
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

  func expectedPreviewScenario(for scenario: String) -> String {
    switch scenario {
    case "open-recent-window", "open-session-window",
      "open-session-window-visual-options-disabled", "agent-detail-form",
      "task-detail-form", "session-search-full", "timeline-filter-form",
      "timeline-burst", "toast-overlay-churn":
      "dashboard-landing"
    case "decision-detail-form", "permission-modal":
      "cockpit"
    case "offline-cached-open":
      "offline-cached"
    default:
      "dashboard"
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
