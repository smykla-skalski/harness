import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
final class HarnessMonitorPerfTests: HarnessMonitorUITestCase {

  // MARK: - Application launch

  func testApplicationLaunchPerformance() {
    measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
      let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
      app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
      app.launchEnvironment["HARNESS_MONITOR_UI_TESTS"] = "1"
      app.launchEnvironment["HARNESS_MONITOR_KEEP_ANIMATIONS"] = "1"
      guard configureIsolatedDataHome(for: app, purpose: "launch-performance") else {
        return
      }
      app.launch()
      app.terminate()
    }
  }

  // MARK: - Scenario hitch rate

  func testLaunchDashboardHitchRate() {
    measureScenario("launch-dashboard")
  }

  func testSelectSessionCockpitHitchRate() {
    measureScenario("select-session-cockpit")
  }

  func testRefreshAndSearchHitchRate() {
    measureScenario("refresh-and-search")
  }

  func testSidebarOverflowSearchHitchRate() {
    measureScenario("sidebar-overflow-search")
  }

  func testSettingsBackdropCycleHitchRate() {
    measureScenario("settings-backdrop-cycle", includeMemoryMetric: true)
  }

  func testSettingsBackgroundCycleHitchRate() {
    measureScenario("settings-background-cycle", includeMemoryMetric: true)
  }

  func testTimelineBurstHitchRate() {
    measureScenario("timeline-burst")
  }

  func testOfflineCachedOpenHitchRate() {
    measureScenario("offline-cached-open", includeMemoryMetric: true)
  }

  func testToastOverlayChurnHitchRate() {
    measureScenario("toast-overlay-churn")
  }

  func testLaunchDashboardScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "launch-dashboard")
    let boardRoot = element(in: launched, identifier: Accessibility.sessionsBoardRoot)
    let sessionRow = sessionTrigger(in: launched, identifier: Accessibility.previewSessionRow)
    let sessionInspectorCard = element(in: launched, identifier: Accessibility.sessionInspectorCard)

    waitForScenarioCompletion(
      app: launched,
      scenario: "launch-dashboard"
    )

    XCTAssertTrue(boardRoot.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertFalse(sessionInspectorCard.exists)
    assertAuditBuildState(in: launched, scenario: "launch-dashboard")

    launched.terminate()
  }

  func testSelectSessionCockpitScenarioState() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: "select-session-cockpit")
    let boardRoot = element(in: launched, identifier: Accessibility.sessionsBoardRoot)
    let sessionInspectorCard = element(in: launched, identifier: Accessibility.sessionInspectorCard)

    if boardRoot.waitForExistence(timeout: Self.actionTimeout) {
      XCTAssertFalse(sessionInspectorCard.exists)
    }

    waitForScenarioCompletion(
      app: launched,
      scenario: "select-session-cockpit"
    )

    XCTAssertTrue(sessionInspectorCard.waitForExistence(timeout: Self.uiTimeout))
    assertAuditBuildState(in: launched, scenario: "select-session-cockpit")

    launched.terminate()
  }

  func testRefreshAndSearchScenarioState() {
    assertSearchHeavyScenarioState("refresh-and-search")
  }

  func testSidebarOverflowSearchScenarioState() {
    assertSearchHeavyScenarioState("sidebar-overflow-search")
  }

  // MARK: - Private

  private func measureScenario(
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

  private func launchForPerf(
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
    guard configureIsolatedDataHome(for: app, purpose: scenario) else {
      return app
    }
    app.launch()
    return app
  }

  private func waitForScenarioCompletion(
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
          && stateText.contains("status=completed")
      },
      "Expected perf scenario \(scenario) to complete within \(Self.actionTimeout)s"
    )
  }

  private func assertSearchHeavyScenarioState(_ scenario: String) {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let launched = launchForPerf(app: app, scenario: scenario)
    let sidebarRoot = element(in: launched, identifier: Accessibility.sidebarRoot)
    let filterState = element(in: launched, identifier: Accessibility.sidebarFilterState)
    let sessionRow = sessionTrigger(in: launched, identifier: Accessibility.previewSessionRow)
    let noMatches = launched.staticTexts["No sessions match"]

    XCTAssertTrue(sidebarRoot.waitForExistence(timeout: Self.uiTimeout))

    waitForScenarioCompletion(
      app: launched,
      scenario: scenario
    )

    XCTAssertTrue(filterState.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertTrue(sessionRow.waitForExistence(timeout: Self.uiTimeout))
    XCTAssertFalse(noMatches.exists)
    XCTAssertTrue(filterState.label.contains("search="))
    XCTAssertTrue(filterState.label.contains("visible="))
    assertAuditBuildState(in: launched, scenario: scenario)

    launched.terminate()
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

  private func expectedPreviewScenario(for scenario: String) -> String {
    switch scenario {
    case "launch-dashboard", "select-session-cockpit":
      "dashboard-landing"
    case "refresh-and-search", "sidebar-overflow-search":
      "overflow"
    case "timeline-burst":
      "cockpit"
    case "toast-overlay-churn":
      "cockpit"
    case "offline-cached-open":
      "offline-cached"
    case "settings-backdrop-cycle", "settings-background-cycle":
      "dashboard"
    default:
      "dashboard"
    }
  }
}
