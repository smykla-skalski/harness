import Foundation
import XCTest

@testable import HarnessMonitor
import HarnessMonitorKit

final class HarnessMonitorAppConfigurationTests: XCTestCase {
  @MainActor
  func testResolveRegistersMCPRegistryHostEnabledOnInjectedStore() throws {
    let suiteName = "io.harnessmonitor.app-tests.mcp-contract"
    let isolated = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { isolated.removePersistentDomain(forName: suiteName) }

    let testEnv = HarnessMonitorEnvironment(
      values: [
        "HARNESS_MONITOR_FORCE_PERSISTENCE_FAILURE": "1",
        "HARNESS_MONITOR_LAUNCH_MODE": HarnessMonitorLaunchMode.preview.rawValue,
      ],
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )

    _ = HarnessMonitorAppConfiguration.resolve(
      defaults: isolated,
      baseEnvironment: testEnv
    )

    let value = isolated.object(
      forKey: HarnessMonitorMCPPreferencesDefaults.registryHostEnabledKey
    ) as? Bool
    XCTAssertEqual(value, true)
  }

  @MainActor
  func testResolvePermissionPerfScenarioSeedsPreviewAcpBatch() {
    let testEnv = HarnessMonitorEnvironment(
      values: [
        "HARNESS_MONITOR_UI_TESTS": "1",
        HarnessMonitorPerfScenario.environmentKey: HarnessMonitorPerfScenario.permissionModal
          .rawValue,
      ],
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )

    let configuration = HarnessMonitorAppConfiguration.resolve(baseEnvironment: testEnv)

    XCTAssertEqual(configuration.perfScenario, .permissionModal)
    XCTAssertEqual(configuration.store.selectedAcpAgents.count, 1)
    XCTAssertEqual(
      configuration.store.pendingAcpPermissionBatches.first?.batchId,
      "preview-acp-permission-1"
    )
  }

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
