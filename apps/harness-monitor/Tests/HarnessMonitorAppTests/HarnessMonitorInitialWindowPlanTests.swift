import Foundation
import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorUIPreviewable

@MainActor
final class HarnessMonitorInitialWindowPlanTests: XCTestCase {
  func testReopensDashboardWhenItWasOpenAtQuit() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(dashboardRestoreState: true)

    XCTAssertEqual(plan.destination, .dashboard)
  }

  func testLeavesDashboardClosedWhenItWasClosedAtQuit() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(dashboardRestoreState: false)

    XCTAssertEqual(plan.destination, .none)
  }

  func testOpensDashboardOnFirstLaunch() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(dashboardRestoreState: nil)

    XCTAssertEqual(plan.destination, .dashboard)
  }

  func testRouterReadsOnlyDashboardRestoreState() {
    let suiteName = "io.harnessmonitor.tests.InitialWindowRouter.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer { userDefaults.removePersistentDomain(forName: suiteName) }
    userDefaults.set(true, forKey: DashboardWindowLifecycleTracker.openAtQuitKey)
    var openCount = 0
    let router = HarnessMonitorInitialWindowRouter(
      userDefaults: userDefaults,
      openDashboardWindow: { openCount += 1 }
    )

    router.route()

    XCTAssertEqual(openCount, 1)
  }
}
