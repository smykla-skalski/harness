import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit

@MainActor
final class SessionWindowPresenceTrackerTests: XCTestCase {
  func testBindsOnFirstAppearanceAndUnbindsOnLastDisappearance() {
    let store = makeStore()
    let notifications = HarnessMonitorUserNotificationController.preview(environment: [:])
    let tracker = makeTracker(store: store, notifications: notifications)

    XCTAssertEqual(tracker.activeSessionWindowCount, 0)
    XCTAssertNil(store.supervisorBindings.notificationController)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsStatusSync)

    tracker.sessionWindowAppeared()

    XCTAssertEqual(tracker.activeSessionWindowCount, 1)
    XCTAssertTrue(store.supervisorBindings.notificationController === notifications)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsStatusSync)

    tracker.sessionWindowAppeared()
    tracker.sessionWindowDisappeared()

    XCTAssertEqual(tracker.activeSessionWindowCount, 1)
    XCTAssertTrue(store.supervisorBindings.notificationController === notifications)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsStatusSync)

    tracker.sessionWindowDisappeared()
    tracker.sessionWindowDisappeared()

    XCTAssertEqual(tracker.activeSessionWindowCount, 0)
    XCTAssertNil(store.supervisorBindings.notificationController)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsStatusSync)
  }

  func testUnbindingSessionWindowUIDoesNotStopRunningSupervisor() async {
    let store = makeStore()
    let tracker = makeTracker(store: store)

    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }
    XCTAssertEqual(store.supervisorRuntimeState, .running)
    XCTAssertNotNil(store.supervisorDecisionStore)

    tracker.sessionWindowAppeared()
    tracker.sessionWindowDisappeared()

    XCTAssertEqual(store.supervisorRuntimeState, .running)
    XCTAssertNotNil(store.supervisorDecisionStore)
    XCTAssertNil(store.supervisorBindings.notificationController)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsStatusSync)
  }

  func testSupervisorCanRunWithoutSessionWindowBindings() async {
    let store = makeStore()

    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    XCTAssertEqual(store.supervisorRuntimeState, .running)
    XCTAssertNil(store.supervisorBindings.notificationController)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsStatusSync)
  }

  private func makeTracker(
    store: HarnessMonitorStore,
    notifications: HarnessMonitorUserNotificationController =
      HarnessMonitorUserNotificationController.preview(environment: [:])
  ) -> SessionWindowPresenceTracker {
    SessionWindowPresenceTracker(
      store: store,
      notificationController: notifications,
      dockBadgeController: PendingDecisionsDockBadgeController(),
      menuBarStatusController: HarnessMonitorMenuBarStatusController()
    )
  }

  private func makeStore() -> HarnessMonitorStore {
    HarnessMonitorStore(
      daemonController: PreviewDaemonController(mode: .empty),
      voiceCapture: PreviewVoiceCaptureService(),
      daemonOwnership: .managed
    )
  }
}
