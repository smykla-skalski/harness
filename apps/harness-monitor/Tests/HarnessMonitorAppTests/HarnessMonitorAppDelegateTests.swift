import Foundation
import XCTest

@testable import HarnessMonitor
import HarnessMonitorKit
import HarnessMonitorUIPreviewable

final class HarnessMonitorAppDelegateTests: XCTestCase {
  func testAppDelegateDetectsHostedXCTestLaunches() {
    XCTAssertTrue(
      HarnessMonitorAppDelegate.isTestHarnessRun(
        environment: ["XCTestConfigurationFilePath": "/tmp/app-tests.xctestconfiguration"],
        bundleIdentifier: "io.harnessmonitor.app",
        processName: "Harness Monitor"
      )
    )
  }

  func testAppDelegateDetectsInjectedXCTestBundles() {
    XCTAssertTrue(
      HarnessMonitorAppDelegate.isTestHarnessRun(
        environment: ["XCInjectBundle": "/tmp/HarnessMonitorAppTests.xctest"],
        bundleIdentifier: "io.harnessmonitor.app",
        processName: "Harness Monitor"
      )
    )
    XCTAssertTrue(
      HarnessMonitorAppDelegate.isTestHarnessRun(
        environment: ["XCInjectBundleInto": "/tmp/Harness Monitor.app"],
        bundleIdentifier: "io.harnessmonitor.app",
        processName: "Harness Monitor"
      )
    )
  }

  func testAppDelegateDetectsUITestHostBundle() {
    XCTAssertTrue(
      HarnessMonitorAppDelegate.isTestHarnessRun(
        environment: [:],
        bundleIdentifier: "io.harnessmonitor.app.ui-testing",
        processName: "Harness Monitor UI Testing"
      )
    )
  }

  func testDefersInitialMainWindowContentOnlyForUITestHostBundle() {
    XCTAssertTrue(
      HarnessMonitorAppConfiguration.shouldDeferInitialMainWindowContentUntilBootstrap(
        isUITesting: true,
        bundleIdentifier: "io.harnessmonitor.app.ui-testing"
      )
    )
    XCTAssertFalse(
      HarnessMonitorAppConfiguration.shouldDeferInitialMainWindowContentUntilBootstrap(
        isUITesting: true,
        bundleIdentifier: "io.harnessmonitor.app"
      )
    )
    XCTAssertFalse(
      HarnessMonitorAppConfiguration.shouldDeferInitialMainWindowContentUntilBootstrap(
        isUITesting: false,
        bundleIdentifier: "io.harnessmonitor.app.ui-testing"
      )
    )
    XCTAssertFalse(
      HarnessMonitorAppConfiguration.shouldDeferInitialMainWindowContentUntilBootstrap(
        isUITesting: true,
        hasPerfScenario: true,
        bundleIdentifier: "io.harnessmonitor.app.ui-testing"
      )
    )
  }

  func testAppDelegateDetectsLoadedXCTestBundles() {
    XCTAssertTrue(
      HarnessMonitorAppDelegate.isTestHarnessRun(
        environment: [:],
        bundleIdentifier: "io.harnessmonitor.app",
        processName: "Harness Monitor",
        loadedBundlePaths: [
          "/Applications/Harness Monitor.app",
          "/tmp/HarnessMonitorAppTests.xctest",
        ]
      )
    )
  }

  func testAppDelegateLeavesNormalAppLaunchesLive() {
    XCTAssertFalse(
      HarnessMonitorAppDelegate.isTestHarnessRun(
        environment: [:],
        bundleIdentifier: "io.harnessmonitor.app",
        processName: "Harness Monitor"
      )
    )
  }
}
