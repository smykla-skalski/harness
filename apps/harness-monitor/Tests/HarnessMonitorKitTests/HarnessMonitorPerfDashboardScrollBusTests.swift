import XCTest

@testable import HarnessMonitorUIPreviewable

final class HarnessMonitorPerfDashboardScrollBusTests: XCTestCase {
  func testIsActiveWhenEnvironmentSelectsLiveScrollScenario() {
    let environment = [
      HarnessMonitorPerfDashboardScrollBus.scenarioEnvironmentKey:
        HarnessMonitorPerfDashboardScrollBus.activeScenarioID
    ]
    XCTAssertTrue(HarnessMonitorPerfDashboardScrollBus.isActive(environment: environment))
  }

  func testIsActiveTrimsWhitespaceInScenarioValue() {
    let environment = [
      HarnessMonitorPerfDashboardScrollBus.scenarioEnvironmentKey:
        " \(HarnessMonitorPerfDashboardScrollBus.activeScenarioID)\n"
    ]
    XCTAssertTrue(HarnessMonitorPerfDashboardScrollBus.isActive(environment: environment))
  }

  func testIsInactiveWhenEnvironmentSelectsDifferentScenario() {
    let environment = [
      HarnessMonitorPerfDashboardScrollBus.scenarioEnvironmentKey: "open-session-window"
    ]
    XCTAssertFalse(HarnessMonitorPerfDashboardScrollBus.isActive(environment: environment))
  }

  func testIsInactiveWhenEnvironmentMissing() {
    XCTAssertFalse(HarnessMonitorPerfDashboardScrollBus.isActive(environment: [:]))
  }

  func testNotificationsHaveStableNames() {
    XCTAssertEqual(
      HarnessMonitorPerfDashboardScrollBus.scrollToBottom.rawValue,
      "io.harnessmonitor.perf.dashboardScroll.bottom"
    )
    XCTAssertEqual(
      HarnessMonitorPerfDashboardScrollBus.scrollToTop.rawValue,
      "io.harnessmonitor.perf.dashboardScroll.top"
    )
  }
}
