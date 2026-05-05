import XCTest

@testable import HarnessMonitorKit

final class SupervisorLifecycleStoreBootstrapTests: XCTestCase {
  @MainActor
  func test_bootstrapIfNeededStartsSupervisor() async throws {
    let store = HarnessMonitorStore.fixture()

    await store.bootstrapIfNeeded()

    try await store.insertDecisionForTesting(DecisionDraft.fixture(id: "d-bootstrap-check"))
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertGreaterThan(
      store.supervisorToolbarSlice.count,
      0,
      "Bootstrap should start the supervisor so decision inserts become visible"
    )
  }

  @MainActor
  func test_setSupervisorRunInBackgroundEnabledStopsAndStartsScheduler() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    UserDefaults.standard.set(true, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      )
    }
    await store.startSupervisor()
    defer { Task { await store.stopSupervisor() } }

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
