import AppKit
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

  func testDockReopenRequestsMainWindowOnlyWhenNoWindowsAreVisible() {
    XCTAssertTrue(
      HarnessMonitorAppDelegate.shouldRequestMainWindowOnReopen(hasVisibleWindows: false)
    )
    XCTAssertFalse(
      HarnessMonitorAppDelegate.shouldRequestMainWindowOnReopen(hasVisibleWindows: true)
    )
  }

  @MainActor
  func testMainWindowLauncherQueuesRequestsUntilSwiftUIBindsOpenWindowAction() {
    let launcher = HarnessMonitorMainWindowLauncher.shared
    launcher.resetForTesting()
    addTeardownBlock { @MainActor in launcher.resetForTesting() }

    launcher.requestOpenMainWindow()
    XCTAssertTrue(launcher.hasPendingOpenRequestForTesting)

    var openCount = 0
    launcher.installOpenMainWindow {
      openCount += 1
    }

    XCTAssertEqual(openCount, 1)
    XCTAssertFalse(launcher.hasPendingOpenRequestForTesting)

    launcher.requestOpenMainWindow()
    XCTAssertEqual(openCount, 2)
  }

  @MainActor
  func testDockReopenQueuesMainWindowRequestWhenOpenWindowActionIsNotBoundYet() {
    let launcher = HarnessMonitorMainWindowLauncher.shared
    launcher.resetForTesting()
    addTeardownBlock { @MainActor in launcher.resetForTesting() }
    let delegate = HarnessMonitorAppDelegate()

    let usesDefaultReopen = delegate.applicationShouldHandleReopen(
      NSApplication.shared,
      hasVisibleWindows: false
    )

    XCTAssertFalse(usesDefaultReopen)
    XCTAssertTrue(launcher.hasPendingOpenRequestForTesting)
  }
}
