import Foundation
import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorUIPreviewable

@MainActor
final class HarnessMonitorInitialWindowPlanTests: XCTestCase {
  func testAlwaysOpenRecentOpensDashboardWithNormalMergeBehavior() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .alwaysOpenRecent,
      dashboardRestoreState: false
    )

    XCTAssertEqual(plan.destination, .dashboard(mergeIfNeeded: true))
  }

  func testRestoreModeReopensDashboardWhenItWasOpenAtQuit() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .restoreSessionWindows,
      dashboardRestoreState: true
    )

    XCTAssertEqual(plan.destination, .dashboard(mergeIfNeeded: false))
  }

  func testRestoreModeLeavesDashboardClosedWhenItWasClosedAtQuit() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .restoreSessionWindows,
      dashboardRestoreState: false
    )

    XCTAssertEqual(plan.destination, .none)
  }

  func testRestoreModeOpensDashboardOnFirstLaunch() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .restoreSessionWindows,
      dashboardRestoreState: nil
    )

    XCTAssertEqual(plan.destination, .dashboard(mergeIfNeeded: true))
  }

  func testRouterReadsOnlyDashboardRestoreState() {
    let suiteName = "io.harnessmonitor.tests.InitialWindowRouter.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    defer { userDefaults.removePersistentDomain(forName: suiteName) }
    userDefaults.set(true, forKey: DashboardWindowLifecycleTracker.openAtQuitKey)
    var mergeFlags: [Bool] = []
    let router = HarnessMonitorInitialWindowRouter(
      launchBehavior: .restoreSessionWindows,
      userDefaults: userDefaults,
      openDashboardWindow: { mergeFlags.append($0) }
    )

    router.route()

    XCTAssertEqual(mergeFlags, [false])
  }
}
