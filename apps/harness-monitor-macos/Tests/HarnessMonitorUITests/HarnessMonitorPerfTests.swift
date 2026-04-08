import XCTest

@MainActor
final class HarnessMonitorPerfTests: HarnessMonitorUITestCase {

  // MARK: - Application launch

  func testApplicationLaunchPerformance() {
    measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
      let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
      app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
      app.launchEnvironment["HARNESS_MONITOR_UI_TESTS"] = "1"
      app.launchEnvironment["HARNESS_MONITOR_LAUNCH_MODE"] = "preview"
      app.launchEnvironment["HARNESS_MONITOR_KEEP_ANIMATIONS"] = "1"
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
    ]
    app.launch()
    return app
  }

  private func waitForScenarioCompletion(
    app: XCUIApplication,
    scenario: String
  ) {
    let window = mainWindow(in: app)
    _ = window.waitForExistence(timeout: Self.uiTimeout)

    let timeout = scenarioWaitDuration(scenario)
    let deadline = Date.now.addingTimeInterval(timeout)
    while Date.now < deadline {
      if app.state == .notRunning {
        return
      }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.5))
    }
  }

  private func scenarioWaitDuration(_ scenario: String) -> TimeInterval {
    switch scenario {
    case "launch-dashboard", "offline-cached-open":
      8
    case "select-session-cockpit", "sidebar-overflow-search", "timeline-burst":
      10
    case "refresh-and-search", "settings-backdrop-cycle",
      "settings-background-cycle":
      12
    default:
      12
    }
  }
}
