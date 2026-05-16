import Foundation
import XCTest

@testable import HarnessMonitor
import HarnessMonitorKit
import HarnessMonitorUIPreviewable

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
      forKey: HarnessMonitorMCPSettingsDefaults.registryHostEnabledKey
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

  @MainActor
  func testResolvePolicyCanvasPerfScenarioSeedsPreviewScenario() {
    let testEnv = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorPerfScenario.environmentKey: HarnessMonitorPerfScenario.policyCanvas
          .rawValue,
      ],
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )

    let configuration = HarnessMonitorAppConfiguration.resolve(baseEnvironment: testEnv)

    XCTAssertEqual(configuration.perfScenario, .policyCanvas)
    XCTAssertEqual(configuration.environment.values["HARNESS_MONITOR_PREVIEW_SCENARIO"], "policy-canvas")
  }

  @MainActor
  func testResolveTaskBoardSettingsPerfScenarioSeedsPreviewScenarioAndInitialSection() {
    let testEnv = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorPerfScenario.environmentKey: HarnessMonitorPerfScenario.taskBoardSettings
          .rawValue,
      ],
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )

    let configuration = HarnessMonitorAppConfiguration.resolve(baseEnvironment: testEnv)

    XCTAssertEqual(configuration.perfScenario, .taskBoardSettings)
    XCTAssertEqual(configuration.environment.values["HARNESS_MONITOR_PREVIEW_SCENARIO"], "dashboard")
    XCTAssertEqual(configuration.settingsInitialSection, .taskBoard)
  }

  @MainActor
  func testResolveAppliesPersistedDaemonOwnershipPreferenceBeforeStoreCreation() throws {
    let suiteName = "io.harnessmonitor.app-tests.daemon-ownership.\(UUID().uuidString)"
    let isolated = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { isolated.removePersistentDomain(forName: suiteName) }

    isolated.set(DaemonOwnership.external.rawValue, forKey: DaemonOwnership.preferenceKey)

    let daemonDataHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-monitor-daemon-pref-\(UUID().uuidString)", isDirectory: true)
    let testEnv = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: daemonDataHome.path,
        "HARNESS_MONITOR_FORCE_PERSISTENCE_FAILURE": "1",
      ],
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )

    let configuration = HarnessMonitorAppConfiguration.resolve(
      defaults: isolated,
      baseEnvironment: testEnv
    )

    XCTAssertEqual(
      configuration.environment.values[DaemonOwnership.environmentKey],
      DaemonOwnership.external.rawValue
    )
    XCTAssertEqual(configuration.store.daemonOwnership, .external)
  }

  @MainActor
  func testResolveExplicitDaemonOwnershipEnvOverridesPersistedExternalPreference() throws {
    let suiteName = "io.harnessmonitor.app-tests.daemon-ownership-env.\(UUID().uuidString)"
    let isolated = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { isolated.removePersistentDomain(forName: suiteName) }

    isolated.set(DaemonOwnership.external.rawValue, forKey: DaemonOwnership.preferenceKey)

    let daemonDataHome = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-monitor-daemon-env-\(UUID().uuidString)", isDirectory: true)
    let testEnv = HarnessMonitorEnvironment(
      values: [
        DaemonOwnership.environmentKey: "0",
        HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: daemonDataHome.path,
        "HARNESS_MONITOR_FORCE_PERSISTENCE_FAILURE": "1",
      ],
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )

    let configuration = HarnessMonitorAppConfiguration.resolve(
      defaults: isolated,
      baseEnvironment: testEnv
    )

    XCTAssertEqual(configuration.environment.values[DaemonOwnership.environmentKey], "0")
    XCTAssertEqual(configuration.store.daemonOwnership, .managed)
  }

  func testDetailPerfScenarioVisualOptionsDisabledDefaultsDisableChrome() {
    let environment = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorPerfScenario.environmentKey:
          HarnessMonitorPerfScenario.decisionDetailFormVisualOptionsDisabled.rawValue,
      ],
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )

    let resolved = HarnessMonitorPerfScenario.decisionDetailFormVisualOptionsDisabled
      .applyingDefaults(to: environment)

    XCTAssertEqual(
      resolved.values[HarnessMonitorAppConfiguration.sessionShortcutOverlaysOverrideKey],
      "0"
    )
    XCTAssertEqual(
      resolved.values[HarnessMonitorAppConfiguration.sessionTitleBlurOverrideKey],
      "0"
    )
    XCTAssertEqual(
      resolved.values[HarnessMonitorAppConfiguration.menuBarStateColorsOverrideKey],
      "0"
    )
    XCTAssertEqual(
      resolved.values["HARNESS_MONITOR_BACKDROP_MODE_OVERRIDE"],
      HarnessMonitorBackdropMode.none.rawValue
    )
    XCTAssertEqual(
      resolved.values["HARNESS_MONITOR_PREVIEW_ACP_PENDING"],
      "1"
    )
  }

  func testPerfScenarioSignpostNamesMatchScenarioIDs() {
    for scenario in HarnessMonitorPerfScenario.allCases {
      XCTAssertEqual(String(describing: scenario.signpostName), scenario.rawValue)
    }
  }

  @MainActor
  func testLaunchMetricsRecorderWritesScenarioReadySample() throws {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-monitor-launch-metrics-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let recorder = HarnessMonitorPerfLaunchMetricsRecorder(
      outputPath: outputURL.path,
      startSystemUptime: 100
    )

    recorder.recordScenarioReady(
      windowID: HarnessMonitorWindowID.dashboard,
      stateLabel: "running",
      includesBootstrapInScenarioMeasurement: false,
      currentSystemUptime: 100.25
    )

    let data = try Data(contentsOf: outputURL)
    let sample = try JSONDecoder().decode(
      HarnessMonitorPerfLaunchMetricSample.self,
      from: data
    )

    XCTAssertEqual(sample.measuredFrom, "app_init")
    XCTAssertEqual(sample.stateLabel, "running")
    XCTAssertEqual(sample.windowID, HarnessMonitorWindowID.dashboard)
    XCTAssertEqual(sample.includesBootstrapInScenarioMeasurement, false)
    XCTAssertEqual(sample.appInitToReadyMilliseconds, 250, accuracy: 0.001)
  }

  @MainActor
  func testLaunchMetricsRecorderOnlyWritesFirstReadySample() throws {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-monitor-launch-metrics-once-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: outputURL) }
    let recorder = HarnessMonitorPerfLaunchMetricsRecorder(
      outputPath: outputURL.path,
      startSystemUptime: 50
    )

    recorder.recordScenarioReady(
      windowID: HarnessMonitorWindowID.dashboard,
      stateLabel: "running",
      includesBootstrapInScenarioMeasurement: true,
      currentSystemUptime: 50.1
    )
    recorder.recordScenarioReady(
      windowID: HarnessMonitorWindowID.settings,
      stateLabel: "completed",
      includesBootstrapInScenarioMeasurement: false,
      currentSystemUptime: 50.9
    )

    let data = try Data(contentsOf: outputURL)
    let sample = try JSONDecoder().decode(
      HarnessMonitorPerfLaunchMetricSample.self,
      from: data
    )

    XCTAssertEqual(sample.windowID, HarnessMonitorWindowID.dashboard)
    XCTAssertEqual(sample.stateLabel, "running")
    XCTAssertEqual(sample.includesBootstrapInScenarioMeasurement, true)
    XCTAssertEqual(sample.appInitToReadyMilliseconds, 100, accuracy: 0.001)
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
