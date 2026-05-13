import XCTest

private typealias Accessibility = HarnessMonitorUITestAccessibility

extension HarnessMonitorPerfTests {
  // MARK: - Application launch

  func testApplicationLaunchPerformance() {
    measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)]) {
      let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
      app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
      app.launchEnvironment["HARNESS_MONITOR_UI_TESTS"] = "1"
      app.launchEnvironment["HARNESS_MONITOR_KEEP_ANIMATIONS"] = "1"
      guard configureIsolatedDataHome(for: app, purpose: "launch-performance") != nil else {
        return
      }
      app.launch()
      app.terminate()
    }
  }

  // MARK: - Scenario hitch rate

  func testOpenRecentWindowHitchRate() {
    measureScenario("open-recent-window")
  }

  func testOpenSessionWindowHitchRate() {
    measureScenario("open-session-window")
  }

  func testAgentDetailFormHitchRate() {
    measureScenario("agent-detail-form")
  }

  func testDecisionDetailFormHitchRate() {
    measureScenario("decision-detail-form")
  }

  func testTaskDetailFormHitchRate() {
    measureScenario("task-detail-form")
  }

  func testSessionSearchFullHitchRate() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let options = XCTMeasureOptions()
    options.iterationCount = 3

    measure(metrics: [XCTHitchMetric(application: app)], options: options) {
      let launched = launchForPerf(app: app, scenario: "session-search-full")
      waitForScenarioCompletion(app: launched, scenario: "session-search-full")
      exerciseSessionSearch(in: launched, query: "worker")
      launched.terminate()
    }
  }

  func testSidebarToggleRichDetailHitchRate() {
    measureScenario("sidebar-toggle-rich-detail")
  }

  func testTimelineFilterFormHitchRate() {
    measureScenario("timeline-filter-form")
  }

  func testPermissionModalHitchRate() {
    measureScenario("permission-modal")
  }

  func testSettingsBackdropCycleHitchRate() {
    measureScenario("settings-backdrop-cycle", includeMemoryMetric: true)
  }

  func testSettingsBackgroundCycleHitchRate() {
    measureScenario("settings-background-cycle", includeMemoryMetric: true)
  }

  func testSettingsDatabaseScrollHitchRate() {
    // UI-test-only coverage: this flow depends on real settings-window scrolling,
    // so it intentionally stays outside the xctrace audit scenario catalog.
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let options = XCTMeasureOptions()
    options.iterationCount = 3

    measure(metrics: [XCTHitchMetric(application: app)], options: options) {
      terminateIfRunning(app)
      app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
      app.launchEnvironment = [
        "HARNESS_MONITOR_UI_TESTS": "1",
        Self.launchModeKey: "preview",
        "HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard",
      ]
      guard
        configureIsolatedDataHome(for: app, purpose: "settings-database-scroll") != nil
      else {
        return
      }

      app.launch()

      openSettings(in: app)
      let settingsRoot = element(in: app, identifier: Accessibility.settingsRoot)
      XCTAssertTrue(waitForElement(settingsRoot, timeout: Self.uiTimeout))

      let databaseItem = button(in: app, title: "Database")
      XCTAssertTrue(waitForElement(databaseItem, timeout: Self.actionTimeout))
      if databaseItem.isHittable {
        databaseItem.tap()
      } else if let coordinate = centerCoordinate(in: app, for: databaseItem) {
        coordinate.tap()
      } else {
        XCTFail("Failed to resolve the Database section control")
        return
      }

      let title = element(in: app, identifier: Accessibility.settingsTitle)
      XCTAssertTrue(
        waitUntil(timeout: Self.actionTimeout) {
          title.exists && title.label == "Database"
        }
      )

      let statisticsHeader = app.staticTexts["Statistics"].firstMatch
      XCTAssertTrue(waitForElement(statisticsHeader, timeout: Self.actionTimeout))
      dragUp(in: app, element: statisticsHeader, distanceRatio: 3.0)

      let clearCacheButton = app.buttons["Clear Session Cache"].firstMatch
      XCTAssertTrue(waitForElement(clearCacheButton, timeout: Self.actionTimeout))

      app.terminate()
    }
  }

  func testTimelineBurstHitchRate() {
    let app = XCUIApplication(bundleIdentifier: Self.uiTestHostBundleIdentifier)
    let signpostMetric = XCTOSSignpostMetric(
      subsystem: "io.harnessmonitor",
      category: "perf",
      name: "timeline-burst"
    )
    let options = XCTMeasureOptions()
    options.iterationCount = 3

    measure(metrics: [XCTHitchMetric(application: app), signpostMetric], options: options) {
      let launched = launchForPerf(app: app, scenario: "timeline-burst")
      waitForScenarioCompletion(app: launched, scenario: "timeline-burst")

      let timelineNav = element(in: launched, identifier: Accessibility.sessionTimelineNavigation)
      if timelineNav.waitForExistence(timeout: Self.actionTimeout) {
        dragUp(in: launched, element: timelineNav, distanceRatio: 2.0)
        dragUp(in: launched, element: timelineNav, distanceRatio: 2.0)
        dragDown(in: launched, element: timelineNav, distanceRatio: 2.0)
        dragUp(in: launched, element: timelineNav, distanceRatio: 2.0)
        dragDown(in: launched, element: timelineNav, distanceRatio: 2.0)
      }

      launched.terminate()
    }
  }

  func testOfflineCachedOpenHitchRate() {
    measureScenario("offline-cached-open", includeMemoryMetric: true)
  }

  func testToastOverlayChurnHitchRate() {
    measureScenario("toast-overlay-churn")
  }
}
