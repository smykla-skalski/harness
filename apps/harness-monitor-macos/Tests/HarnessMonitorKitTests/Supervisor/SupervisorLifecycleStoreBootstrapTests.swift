import XCTest

@testable import HarnessMonitorKit

final class SupervisorLifecycleStoreBootstrapTests: XCTestCase {
  func test_bootstrapSupervisorAutostartPolicyRunsOutsideXCTestHost() {
    XCTAssertTrue(
      HarnessMonitorStore.shouldStartSupervisorOnBootstrap(environment: [:])
    )
  }

  func test_bootstrapSupervisorAutostartPolicySkipsXCTestHost() {
    XCTAssertFalse(
      HarnessMonitorStore.shouldStartSupervisorOnBootstrap(
        environment: [
          "XCTestConfigurationFilePath": "/tmp/HarnessMonitorKitTests.xctestconfiguration"
        ]
      )
    )
  }

  func test_bootstrapSupervisorAutostartPolicyCanOptInInsideXCTestHost() {
    XCTAssertTrue(
      HarnessMonitorStore.shouldStartSupervisorOnBootstrap(
        environment: [
          "XCTestConfigurationFilePath": "/tmp/HarnessMonitorKitTests.xctestconfiguration",
          "HARNESS_MONITOR_ENABLE_BOOTSTRAP_SUPERVISOR_IN_TESTS": "1",
        ]
      )
    )
  }

  @MainActor
  func test_setSupervisorRunInBackgroundEnabledStopsAndStartsScheduler() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    UserDefaults.standard.set(true, forKey: SupervisorSettingsDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorSettingsDefaults.runInBackgroundKey
      )
    }
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    XCTAssertTrue(store.isSupervisorBackgroundActivityScheduledForTesting())
    XCTAssertTrue(store.isSupervisorAuditRetentionScheduledForTesting())

    store.setSupervisorRunInBackgroundEnabled(false)
    XCTAssertFalse(store.isSupervisorBackgroundActivityScheduledForTesting())
    XCTAssertFalse(store.isSupervisorAuditRetentionScheduledForTesting())

    store.setSupervisorRunInBackgroundEnabled(true)
    XCTAssertTrue(store.isSupervisorBackgroundActivityScheduledForTesting())
    XCTAssertTrue(store.isSupervisorAuditRetentionScheduledForTesting())
  }

}
