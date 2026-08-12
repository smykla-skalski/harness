import XCTest

import HarnessMonitorKit
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

  func testTaskBoardLaneScrollRequestEmitsTypedLaneRawValue() {
    let notification = expectation(
      forNotification: HarnessMonitorPerfTaskBoardLaneScrollBus.scrollToBottom,
      object: nil
    ) { notification in
      XCTAssertEqual(
        notification.userInfo?[HarnessMonitorPerfTaskBoardLaneScrollBus.laneRawKey] as? String,
        "human_required"
      )
      return true
    }

    HarnessMonitorPerfTaskBoardLaneScrollBus.requestScroll(
      lane: .humanRequired,
      edge: "bottom"
    )

    wait(for: [notification], timeout: 1)
  }
}
