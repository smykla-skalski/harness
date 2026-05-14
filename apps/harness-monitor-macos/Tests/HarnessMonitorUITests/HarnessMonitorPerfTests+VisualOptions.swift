import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension HarnessMonitorPerfTests {
  private static let visualOptionsDisabledScenarios =
    HarnessMonitorUITestPerfScenarioCatalog.visualOptionsDisabledScenarios

  func testAgentDetailFormVisualOptionsDisabledHitchRate() {
    measureScenario("agent-detail-form-visual-options-disabled")
  }

  func testDecisionDetailFormVisualOptionsDisabledHitchRate() {
    measureScenario("decision-detail-form-visual-options-disabled")
  }

  func testOpenSessionWindowVisualOptionsDisabledHitchRate() {
    measureScenario("open-session-window-visual-options-disabled")
  }

  func testSessionSearchFullVisualOptionsDisabledHitchRate() {
    measureScenario("session-search-full-visual-options-disabled")
  }

  func testSidebarToggleRichDetailVisualOptionsDisabledHitchRate() {
    measureScenario("sidebar-toggle-rich-detail-visual-options-disabled")
  }

  func testTaskDetailFormVisualOptionsDisabledHitchRate() {
    measureScenario("task-detail-form-visual-options-disabled")
  }

  func testTimelineFilterFormVisualOptionsDisabledHitchRate() {
    measureScenario("timeline-filter-form-visual-options-disabled")
  }

  func testAgentDetailFormVisualOptionsDisabledScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(
      app: app,
      scenario: "agent-detail-form-visual-options-disabled"
    )
    defer { launched.terminate() }
    let agentDetail = element(in: launched, identifier: Accessibility.agentDetailScrollView)

    assertVisualOptionsDisabledScenarioState(
      in: launched,
      scenario: "agent-detail-form-visual-options-disabled",
      requiredElement: agentDetail,
      requiredElementDescription:
        "Agent detail visual-options-disabled perf scenario did not render the current agent detail pane"
    )
  }

  func testDecisionDetailFormVisualOptionsDisabledScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(
      app: app,
      scenario: "decision-detail-form-visual-options-disabled"
    )
    defer { launched.terminate() }
    let decisionDetail = element(in: launched, identifier: Accessibility.decisionDetailScrollView)

    assertVisualOptionsDisabledScenarioState(
      in: launched,
      scenario: "decision-detail-form-visual-options-disabled",
      requiredElement: decisionDetail,
      requiredElementDescription:
        "Decision detail visual-options-disabled perf scenario did not render "
        + "the current decision detail pane"
    )
  }

  func testOpenSessionWindowVisualOptionsDisabledScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(
      app: app,
      scenario: "open-session-window-visual-options-disabled"
    )
    defer { launched.terminate() }

    assertVisualOptionsDisabledScenarioState(
      in: launched,
      scenario: "open-session-window-visual-options-disabled"
    )
  }

  func testSessionSearchFullVisualOptionsDisabledScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(
      app: app,
      scenario: "session-search-full-visual-options-disabled"
    )
    defer { launched.terminate() }
    let searchField = mainWindow(in: launched).searchFields.firstMatch

    assertVisualOptionsDisabledScenarioState(
      in: launched,
      scenario: "session-search-full-visual-options-disabled",
      requiredElement: searchField,
      requiredElementDescription:
        "Session search visual-options-disabled perf scenario should expose the native toolbar search field"
    )
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
    defer { launched.terminate() }

    assertVisualOptionsDisabledScenarioState(
      in: launched,
      scenario: "sidebar-toggle-rich-detail-visual-options-disabled",
      requiredElement: timelineFilterBar,
      requiredElementDescription:
        "Sidebar toggle visual-options-disabled perf scenario should finish on the timeline surface"
    )
    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
  }

  func testTaskDetailFormVisualOptionsDisabledScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(
      app: app,
      scenario: "task-detail-form-visual-options-disabled"
    )
    defer { launched.terminate() }
    let taskDetail = element(in: launched, identifier: Accessibility.sessionTaskDetailScrollView)

    assertVisualOptionsDisabledScenarioState(
      in: launched,
      scenario: "task-detail-form-visual-options-disabled",
      requiredElement: taskDetail,
      requiredElementDescription:
        "Task detail visual-options-disabled perf scenario did not render the current task detail pane"
    )
  }

  func testTimelineFilterFormVisualOptionsDisabledScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(
      app: app,
      scenario: "timeline-filter-form-visual-options-disabled"
    )
    defer { launched.terminate() }
    let filterState = element(in: launched, identifier: Accessibility.sessionTimelineFilterState)

    assertVisualOptionsDisabledScenarioState(
      in: launched,
      scenario: "timeline-filter-form-visual-options-disabled",
      requiredElement: filterState,
      requiredElementDescription:
        "Timeline filter visual-options-disabled perf scenario did not seed the active filter state"
    )
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

  private func assertVisualOptionsDisabledScenarioState(
    in app: XCUIApplication,
    scenario: String,
    requiredElement: XCUIElement? = nil,
    requiredElementDescription: String? = nil
  ) {
    let sessionWindow = element(in: app, identifier: Accessibility.sessionWindowShell)

    waitForScenarioCompletion(
      app: app,
      scenario: scenario
    )

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    if let requiredElement {
      XCTAssertTrue(
        waitForElement(requiredElement, timeout: Self.uiTimeout),
        requiredElementDescription
          ?? "Visual-options-disabled perf scenario \(scenario) did not render its expected state"
      )
    }
    assertPerfVisualOptionsDisabled(
      in: app,
      scenario: scenario
    )
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
