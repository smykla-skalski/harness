import Foundation
import XCTest

@testable import HarnessMonitor
import HarnessMonitorKit

/// Covers `HarnessMonitorPerfScenario.applyingDefaults(to:)` for live-daemon
/// scenarios. Without this, an audit run's `AuditRunner+Recording.recordOne`
/// seeds `HARNESS_MONITOR_PREVIEW_SCENARIO` for every scenario and
/// `HarnessMonitorAppStoreFactory.makeStore` returns a preview store whenever
/// that key is non-empty, which silently renders the static dashboard instead
/// of the real app. `dashboardSidebarToggle` (with `usesLiveDaemon: true` in
/// the scenarios JSON) depends on the strip + launch-mode default for the
/// live-daemon trace to be valid.
extension HarnessMonitorAppConfigurationTests {
  func testApplyingDefaultsStripsPreviewScenarioForLiveDaemonScenario() {
    let environment = HarnessMonitorEnvironment(values: [
      "HARNESS_MONITOR_PREVIEW_SCENARIO": "dashboard"
    ])

    let resolved = HarnessMonitorPerfScenario.dashboardSidebarToggle
      .applyingDefaults(to: environment)

    XCTAssertNil(resolved.values["HARNESS_MONITOR_PREVIEW_SCENARIO"])
  }

  func testApplyingDefaultsDefaultsLaunchModeLiveForLiveDaemonScenario() {
    let environment = HarnessMonitorEnvironment(values: [:])

    let resolved = HarnessMonitorPerfScenario.dashboardSidebarToggle
      .applyingDefaults(to: environment)

    XCTAssertEqual(
      resolved.values[HarnessMonitorLaunchMode.environmentKey],
      HarnessMonitorLaunchMode.live.rawValue
    )
  }

  func testApplyingDefaultsPreservesExplicitLaunchModeForLiveDaemonScenario() {
    let environment = HarnessMonitorEnvironment(values: [
      HarnessMonitorLaunchMode.environmentKey: HarnessMonitorLaunchMode.preview.rawValue
    ])

    let resolved = HarnessMonitorPerfScenario.dashboardSidebarToggle
      .applyingDefaults(to: environment)

    XCTAssertEqual(
      resolved.values[HarnessMonitorLaunchMode.environmentKey],
      HarnessMonitorLaunchMode.preview.rawValue
    )
  }

  func testApplyingDefaultsKeepsPreviewScenarioSeedForNonLiveDaemonScenario() {
    let environment = HarnessMonitorEnvironment(values: [:])

    let resolved = HarnessMonitorPerfScenario.openRecentWindow
      .applyingDefaults(to: environment)

    // Non-live-daemon scenarios fall through to the preview-seed branch.
    XCTAssertEqual(
      resolved.values[HarnessMonitorLaunchMode.environmentKey],
      HarnessMonitorLaunchMode.preview.rawValue
    )
    XCTAssertNotNil(resolved.values["HARNESS_MONITOR_PREVIEW_SCENARIO"])
  }
}
