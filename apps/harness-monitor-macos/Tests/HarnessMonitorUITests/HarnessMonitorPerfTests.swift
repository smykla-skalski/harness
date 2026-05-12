import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorPerfTests: HarnessMonitorUITestCase {
  private static let previewSessionID = "sess1234"

  func testOpenRecentWindowScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "open-recent-window")
    let openRecentRoot = element(in: launched, identifier: Accessibility.openRecentRoot)
    let projectList = element(in: launched, identifier: Accessibility.openRecentProjectList)
    let sessionRow = element(
      in: launched,
      identifier: Accessibility.openRecentSessionRow(Self.previewSessionID)
    )
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)

    waitForScenarioCompletion(app: launched, scenario: "open-recent-window")

    XCTAssertTrue(openRecentRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(projectList.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertFalse(sessionWindow.exists)

    launched.terminate()
  }

  func testLaunchForPerfSeedsObservabilityConfigIntoIsolatedDataHome() throws {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)

    XCTAssertNotNil(
      configureIsolatedDataHome(for: app, purpose: "perf-observability-config")
    )

    let isolatedRoot = try XCTUnwrap(app.launchEnvironment[Self.daemonDataHomeKey])
    let configURL = URL(fileURLWithPath: isolatedRoot, isDirectory: true)
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("observability", isDirectory: true)
      .appendingPathComponent("config.json")

    XCTAssertTrue(
      FileManager.default.fileExists(atPath: configURL.path),
      "Expected isolated perf runs to seed an observability config"
    )
    let configBody = try String(contentsOf: configURL, encoding: .utf8)
    XCTAssertTrue(configBody.contains("\"enabled\": true"))
    XCTAssertTrue(configBody.contains("\"grpc_endpoint\": \"http://127.0.0.1:4317\""))
  }

  func testOpenSessionWindowScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "open-session-window")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)

    waitForScenarioCompletion(app: launched, scenario: "open-session-window")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))

    launched.terminate()
  }

  func testAgentDetailFormScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "agent-detail-form")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let agentDetail = element(in: launched, identifier: Accessibility.agentDetailScrollView)

    waitForScenarioCompletion(app: launched, scenario: "agent-detail-form")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitForElement(agentDetail, timeout: Self.uiTimeout),
      "Agent detail perf scenario did not render the current agent detail pane"
    )
    XCTAssertTrue(
      launched.staticTexts["Codex Worker"].firstMatch.waitForExistence(timeout: Self.actionTimeout)
    )

    launched.terminate()
  }

  func testDecisionDetailFormScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "decision-detail-form")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let decisionDetail = element(in: launched, identifier: Accessibility.decisionDetailScrollView)
    let acpPanel = element(in: launched, identifier: Accessibility.decisionAcpPanel)

    waitForScenarioCompletion(app: launched, scenario: "decision-detail-form")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitForElement(decisionDetail, timeout: Self.uiTimeout),
      "Decision detail perf scenario did not render the current decision detail pane"
    )
    XCTAssertTrue(
      waitForElement(acpPanel, timeout: Self.actionTimeout),
      "Decision detail perf scenario did not render the ACP decision form"
    )

    launched.terminate()
  }

  func testTaskDetailFormScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "task-detail-form")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let taskDetail = element(in: launched, identifier: Accessibility.sessionTaskDetailScrollView)

    waitForScenarioCompletion(app: launched, scenario: "task-detail-form")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitForElement(taskDetail, timeout: Self.uiTimeout),
      "Task detail perf scenario did not render the current task detail pane"
    )
    XCTAssertTrue(
      launched.buttons["Task Actions"].firstMatch.waitForExistence(timeout: Self.actionTimeout)
    )

    launched.terminate()
  }

  func testSessionSearchFullScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "session-search-full")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let searchField = mainWindow(in: launched).searchFields.firstMatch

    waitForScenarioCompletion(app: launched, scenario: "session-search-full")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitForElement(searchField, timeout: Self.uiTimeout),
      "Session search perf scenario should expose the native toolbar search field"
    )
    exerciseSessionSearch(in: launched, query: "worker")
    XCTAssertTrue(
      launched.staticTexts["Codex Worker"].firstMatch.waitForExistence(timeout: Self.actionTimeout)
    )

    launched.terminate()
  }

  func testTimelineFilterFormScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "timeline-filter-form")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let filterBar = element(in: launched, identifier: Accessibility.sessionTimelineFilterBar)
    let filterState = element(in: launched, identifier: Accessibility.sessionTimelineFilterState)

    waitForScenarioCompletion(app: launched, scenario: "timeline-filter-form")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(waitForElement(filterBar, timeout: Self.uiTimeout))
    XCTAssertTrue(waitForElement(filterState, timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout) {
        let text = self.markerText(filterState)
        return text.contains("query=worker")
          && text.contains("agents=worker-codex")
          && text.contains("tasks=task-ui")
      },
      "Timeline filter perf scenario did not seed the expected active filters"
    )

    launched.terminate()
  }

  func testPermissionModalScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "permission-modal")
    let sessionWindow = element(in: launched, identifier: Accessibility.sessionWindowShell)
    let decisionID = "acp-permission:preview-acp-permission-1"
    let decisionRow = element(in: launched, identifier: Accessibility.decisionRow(decisionID))
    let legacyModal = element(in: launched, identifier: Accessibility.acpPermissionModal)

    waitForScenarioCompletion(app: launched, scenario: "permission-modal")

    XCTAssertTrue(sessionWindow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(
      waitForElement(decisionRow, timeout: Self.uiTimeout),
      "Permission perf scenario did not surface the routed ACP decision row"
    )
    XCTAssertFalse(legacyModal.exists)

    launched.terminate()
  }

  // MARK: - Private

  func measureScenario(
    _ scenarioRawValue: String,
    includeMemoryMetric: Bool = false
  ) {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let signpostMetric = XCTOSSignpostMetric(
      subsystem: "io.harnessmonitor",
      category: "perf",
      name: scenarioRawValue
    )
    var metrics: [any XCTMetric] = [
      XCTHitchMetric(application: app),
      signpostMetric,
    ]
    if includeMemoryMetric {
      metrics.append(XCTMemoryMetric(application: app))
    }

    let options = XCTMeasureOptions()
    options.iterationCount = 3

    measure(metrics: metrics, options: options) {
      let launched = launchForPerf(app: app, scenario: scenarioRawValue)
      waitForScenarioCompletion(
        app: launched,
        scenario: scenarioRawValue
      )
      launched.terminate()
    }
  }

  func launchForPerf(
    app: XCUIApplication,
    scenario: String
  ) -> XCUIApplication {
    terminateIfRunning(app)
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    app.launchEnvironment = [
      "HARNESS_MONITOR_UI_TESTS": "1",
      "HARNESS_MONITOR_KEEP_ANIMATIONS": "1",
      "HARNESS_MONITOR_PERF_SCENARIO": scenario,
      "HARNESS_MONITOR_PREVIEW_SCENARIO": expectedPreviewScenario(for: scenario),
      "HARNESS_MONITOR_PERF_STEP_DELAY_MS": "120",
      "HARNESS_MONITOR_PERF_SHORT_DELAY_MS": "60",
      "HARNESS_MONITOR_PERF_SETTLE_DELAY_MS": "180",
    ]
    guard configureIsolatedDataHome(for: app, purpose: scenario) != nil else {
      return app
    }
    app.launch()
    return app
  }

  func waitForScenarioCompletion(
    app: XCUIApplication,
    scenario: String
  ) {
    let window = mainWindow(in: app)
    _ = window.waitForExistence(timeout: Self.actionTimeout)
    let perfState = element(in: app, identifier: Accessibility.perfScenarioState)

    XCTAssertTrue(
      perfState.waitForExistence(timeout: Self.actionTimeout),
      "Expected perf scenario marker for \(scenario)"
    )
    XCTAssertTrue(
      waitUntil(timeout: Self.actionTimeout, pollInterval: 0.05) {
        if app.state == .notRunning {
          return false
        }
        let stateText = self.markerText(perfState)
        return
          stateText.contains("scenario=\(scenario)")
          && (stateText.contains("status=completed") || stateText.contains("status=failed"))
      },
      "Expected perf scenario \(scenario) to finish within \(Self.actionTimeout)s"
    )
    let stateText = markerText(perfState)
    XCTAssertFalse(
      stateText.contains("status=failed"),
      "Perf scenario \(scenario) failed early: \(stateText)"
    )
  }

  func exerciseSessionSearch(in app: XCUIApplication, query: String) {
    let searchField = mainWindow(in: app).searchFields.firstMatch
    guard waitForElement(searchField, timeout: Self.actionTimeout) else {
      XCTFail("Expected native session search field before typing \(query)")
      return
    }
    searchField.tap()
    app.typeKey("a", modifierFlags: .command)
    searchField.typeText(query)
  }

  private func assertAuditBuildState(in app: XCUIApplication, scenario: String) {
    let auditBuildState = element(in: app, identifier: Accessibility.auditBuildState)

    XCTAssertTrue(auditBuildState.waitForExistence(timeout: Self.actionTimeout))
    let auditText = markerText(auditBuildState)

    XCTAssertTrue(
      auditText.contains("launchMode=preview"),
      """
      Audit marker missing preview launch mode. label='\(auditBuildState.label)' \
      value='\(String(describing: auditBuildState.value))'
      """
    )
    XCTAssertTrue(
      auditText.contains("perfScenario=\(scenario)"),
      """
      Audit marker missing perf scenario \(scenario). label='\(auditBuildState.label)' \
      value='\(String(describing: auditBuildState.value))'
      """
    )
    let expectedScenario = expectedPreviewScenario(for: scenario)
    XCTAssertTrue(
      auditText.contains("previewScenario=\(expectedScenario)"),
      """
      Audit marker missing preview scenario \(expectedScenario). \
      label='\(auditBuildState.label)' \
      value='\(String(describing: auditBuildState.value))'
      """
    )
    XCTAssertFalse(
      auditText.contains("buildCommit=unknown"),
      """
      Audit marker missing embedded build commit. label='\(auditBuildState.label)' \
      value='\(String(describing: auditBuildState.value))'
      """
    )
    XCTAssertFalse(
      auditText.contains("buildDirty=unknown"),
      """
      Audit marker missing embedded build dirty state. label='\(auditBuildState.label)' \
      value='\(String(describing: auditBuildState.value))'
      """
    )
    XCTAssertFalse(
      auditText.contains("buildFingerprint=unknown"),
      """
      Audit marker missing embedded build fingerprint. label='\(auditBuildState.label)' \
      value='\(String(describing: auditBuildState.value))'
      """
    )
  }

  private func markerText(_ element: XCUIElement) -> String {
    if !element.label.isEmpty {
      return element.label
    }

    if let value = element.value as? String, !value.isEmpty {
      return value
    }

    return element.debugDescription
  }

}
