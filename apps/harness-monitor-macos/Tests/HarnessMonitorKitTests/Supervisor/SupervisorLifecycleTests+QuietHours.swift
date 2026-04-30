import XCTest

@testable import HarnessMonitorKit

@MainActor
extension SupervisorLifecycleTests {
  func testSetSupervisorQuietHoursWindowUpdatesRuntimeSuppression() async {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    defer { Task { await store.stopSupervisor() } }

    await store.applySupervisorQuietHoursWindowForTesting(
      SupervisorQuietHoursWindow(startMinutes: 0, endMinutes: 0)
    )
    let isSuppressed = await store.isSupervisorAutoActionSuppressedForTesting(at: .fixed)
    XCTAssertTrue(isSuppressed)

    await store.applySupervisorQuietHoursWindowForTesting(nil)
    let isCleared = await store.isSupervisorAutoActionSuppressedForTesting(at: .fixed)
    XCTAssertFalse(isCleared)
  }
}
