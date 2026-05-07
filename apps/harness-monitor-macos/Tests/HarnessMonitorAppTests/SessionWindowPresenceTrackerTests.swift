import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit

@MainActor
final class SessionWindowPresenceTrackerTests: XCTestCase {
  func testBindsOnFirstAppearanceAndUnbindsOnLastDisappearance() {
    let store = makeStore()
    let notifications = HarnessMonitorUserNotificationController.preview(environment: [:])
    let tracker = makeTracker(store: store, notifications: notifications)
    let firstWindow = NSObject()
    let secondWindow = NSObject()
    let firstWindowID = ObjectIdentifier(firstWindow)
    let secondWindowID = ObjectIdentifier(secondWindow)

    XCTAssertEqual(tracker.activeSessionWindowCount, 0)
    XCTAssertNil(store.supervisorBindings.notificationController)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsStatusSync)

    tracker.sessionWindowAppeared(windowID: firstWindowID)

    XCTAssertEqual(tracker.activeSessionWindowCount, 1)
    XCTAssertTrue(store.supervisorBindings.notificationController === notifications)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsStatusSync)

    tracker.sessionWindowAppeared(windowID: firstWindowID)
    tracker.sessionWindowAppeared(windowID: secondWindowID)
    tracker.sessionWindowDisappeared(windowID: firstWindowID)

    XCTAssertEqual(tracker.activeSessionWindowCount, 1)
    XCTAssertTrue(store.supervisorBindings.notificationController === notifications)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsStatusSync)

    tracker.sessionWindowDisappeared(windowID: firstWindowID)
    tracker.sessionWindowDisappeared(windowID: secondWindowID)

    XCTAssertEqual(tracker.activeSessionWindowCount, 0)
    XCTAssertNil(store.supervisorBindings.notificationController)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsStatusSync)
  }

  func testUnbindingSessionWindowUIDoesNotStopRunningSupervisor() async {
    let store = makeStore()
    let tracker = makeTracker(store: store)
    let window = NSObject()
    let windowID = ObjectIdentifier(window)

    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }
    XCTAssertEqual(store.supervisorRuntimeState, .running)
    XCTAssertNotNil(store.supervisorDecisionStore)

    tracker.sessionWindowAppeared(windowID: windowID)
    tracker.sessionWindowDisappeared(windowID: windowID)

    XCTAssertEqual(store.supervisorRuntimeState, .running)
    XCTAssertNotNil(store.supervisorDecisionStore)
    XCTAssertNil(store.supervisorBindings.notificationController)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsStatusSync)
  }

  func testMenuBarSnapshotShowsExplicitIdleMonitoringState() {
    let snapshot = HarnessMonitorMenuBarSnapshot(
      connectionState: .idle,
      sessionCount: 3,
      pendingDecisionCount: 2,
      pendingDecisionSeverity: .warn,
      supervisorRuntimeState: .running,
      activeSessionWindowCount: 0,
      runsWhenClosed: true
    )

    XCTAssertEqual(
      snapshot.monitoringLabel,
      HarnessMonitorMenuBarSnapshot.idleMonitoringLabel
    )
    XCTAssertEqual(snapshot.supervisorLabel, "Supervisor: Running in background")
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
