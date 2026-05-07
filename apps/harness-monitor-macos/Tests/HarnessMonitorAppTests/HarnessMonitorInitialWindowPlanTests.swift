import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit

final class HarnessMonitorInitialWindowPlanTests: XCTestCase {
  func testVisibleWindowsSuppressAdditionalLaunchActions() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .restoreSessionWindows,
      hasVisibleWindows: true,
      restorePlan: .init(sessionIDs: ["sess-a"], usedBridgeFallback: true)
    )

    XCTAssertEqual(plan.destination, .none)
    XCTAssertFalse(plan.shouldMarkBridgeFallbackComplete)
  }

  func testAlwaysOpenRecentOpensWelcomeWindow() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .alwaysOpenRecent,
      hasVisibleWindows: false
    )

    XCTAssertEqual(plan.destination, .welcome)
    XCTAssertFalse(plan.shouldMarkBridgeFallbackComplete)
  }

  func testRestoreSessionWindowsOpensTrackedSessions() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .restoreSessionWindows,
      hasVisibleWindows: false,
      restorePlan: .init(sessionIDs: ["sess-a", "sess-b"], usedBridgeFallback: true)
    )

    XCTAssertEqual(plan.destination, .sessions(["sess-a", "sess-b"]))
    XCTAssertTrue(plan.shouldMarkBridgeFallbackComplete)
  }

  func testRestoreSessionWindowsFallsBackToWelcomeWhenNothingRestored() {
    let plan = HarnessMonitorInitialWindowPlan.resolve(
      launchBehavior: .restoreSessionWindows,
      hasVisibleWindows: false,
      restorePlan: .init(sessionIDs: [], usedBridgeFallback: true)
    )

    XCTAssertEqual(plan.destination, .welcome)
    XCTAssertTrue(plan.shouldMarkBridgeFallbackComplete)
  }
}
