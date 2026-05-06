import XCTest

@testable import HarnessMonitor

final class HarnessMonitorAppLifecyclePolicyTests: XCTestCase {
  func testNormalLaunchKeepsProcessAliveAfterLastWindowCloses() {
    XCTAssertFalse(
      HarnessMonitorAppDelegate.shouldTerminateAfterLastWindowClosed(isTestHarnessRun: false)
    )
  }

  func testTestHarnessLaunchTerminatesAfterLastWindowCloses() {
    XCTAssertTrue(
      HarnessMonitorAppDelegate.shouldTerminateAfterLastWindowClosed(isTestHarnessRun: true)
    )
  }
}
