import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

@MainActor
extension HarnessMonitorPerfTests {
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

  func acceptFirstNativeSearchSuggestion(in app: XCUIApplication) {
    app.typeKey(.downArrow, modifierFlags: [])
    app.typeKey(.return, modifierFlags: [])
  }

  func markerText(_ element: XCUIElement) -> String {
    if !element.label.isEmpty {
      return element.label
    }

    if let value = element.value as? String, !value.isEmpty {
      return value
    }

    return element.debugDescription
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
}
