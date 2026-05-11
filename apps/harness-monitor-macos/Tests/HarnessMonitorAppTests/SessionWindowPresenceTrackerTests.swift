import XCTest

@testable import HarnessMonitor
@testable import HarnessMonitorKit

@MainActor
final class SessionWindowPresenceTrackerTests: XCTestCase {
  func testTrackerCountsActiveSessionWindows() {
    let tracker = SessionWindowPresenceTracker()
    let firstWindow = NSObject()
    let secondWindow = NSObject()
    let firstWindowID = ObjectIdentifier(firstWindow)
    let secondWindowID = ObjectIdentifier(secondWindow)

    XCTAssertEqual(tracker.activeSessionWindowCount, 0)

    tracker.sessionWindowAppeared(windowID: firstWindowID)
    XCTAssertEqual(tracker.activeSessionWindowCount, 1)

    tracker.sessionWindowAppeared(windowID: firstWindowID)
    tracker.sessionWindowAppeared(windowID: secondWindowID)
    XCTAssertEqual(tracker.activeSessionWindowCount, 2)

    tracker.sessionWindowDisappeared(windowID: firstWindowID)
    XCTAssertEqual(tracker.activeSessionWindowCount, 1)

    tracker.sessionWindowDisappeared(windowID: secondWindowID)
    XCTAssertEqual(tracker.activeSessionWindowCount, 0)
  }

  func testTrackerDoesNotOwnSupervisorBindings() {
    let store = makeStore()
    let tracker = SessionWindowPresenceTracker()
    let window = NSObject()
    let windowID = ObjectIdentifier(window)

    XCTAssertNil(store.supervisorBindings.notificationController)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsStatusSync)

    tracker.sessionWindowAppeared(windowID: windowID)
    tracker.sessionWindowDisappeared(windowID: windowID)

    XCTAssertNil(store.supervisorBindings.notificationController)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNil(store.supervisorBindings.pendingDecisionsStatusSync)
  }

  func testAppLaunchBindsSupervisorSurfacesIndependentlyOfSessionWindows() {
    let store = makeStore()
    let notifications = HarnessMonitorUserNotificationController.preview(environment: [:])
    let dockBadge = PendingDecisionsDockBadgeController()
    let menuBarStatus = HarnessMonitorMenuBarStatusController()

    HarnessMonitorApp.bindSupervisorSurfaces(
      to: store,
      notificationController: notifications,
      dockBadgeController: dockBadge,
      menuBarStatusController: menuBarStatus
    )

    XCTAssertTrue(store.supervisorBindings.notificationController === notifications)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsStatusSync)
  }

  func testSupervisorRunsWithBindingsAttachedFromAppLaunch() async {
    let store = makeStore()
    let notifications = HarnessMonitorUserNotificationController.preview(environment: [:])
    HarnessMonitorApp.bindSupervisorSurfaces(
      to: store,
      notificationController: notifications,
      dockBadgeController: PendingDecisionsDockBadgeController(),
      menuBarStatusController: HarnessMonitorMenuBarStatusController()
    )

    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    XCTAssertEqual(store.supervisorRuntimeState, .running)
    XCTAssertTrue(store.supervisorBindings.notificationController === notifications)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsStatusSync)
  }

  func testBindingsPersistAfterAllSessionWindowsClose() async {
    let store = makeStore()
    let notifications = HarnessMonitorUserNotificationController.preview(environment: [:])
    HarnessMonitorApp.bindSupervisorSurfaces(
      to: store,
      notificationController: notifications,
      dockBadgeController: PendingDecisionsDockBadgeController(),
      menuBarStatusController: HarnessMonitorMenuBarStatusController()
    )
    let tracker = SessionWindowPresenceTracker()
    let window = NSObject()
    let windowID = ObjectIdentifier(window)

    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    tracker.sessionWindowAppeared(windowID: windowID)
    tracker.sessionWindowDisappeared(windowID: windowID)

    XCTAssertEqual(tracker.activeSessionWindowCount, 0)
    XCTAssertTrue(store.supervisorBindings.notificationController === notifications)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsBadgeSync)
    XCTAssertNotNil(store.supervisorBindings.pendingDecisionsStatusSync)
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

  func testLifecycleModifierUsesNativeSwiftUILifecycle() throws {
    let source = try harnessSourceFile(named: "App/SessionWindowLifecycleModifier.swift")

    XCTAssertTrue(source.contains(".task(id: sessionID)"))
    XCTAssertTrue(source.contains(".onDisappear"))
    XCTAssertFalse(source.contains("import AppKit"))
    XCTAssertFalse(source.contains("NSViewRepresentable"))
    XCTAssertFalse(source.contains("NSWindow"))
  }

  func testPresenceTrackerSourceDoesNotBindSupervisorSurfaces() throws {
    let trackerSource = try harnessSourceFile(named: "App/SessionWindowPresenceTracker.swift")

    XCTAssertFalse(trackerSource.contains("bindSupervisorNotifications"))
    XCTAssertFalse(trackerSource.contains("bindPendingDecisionsBadgeSync"))
    XCTAssertFalse(trackerSource.contains("bindPendingDecisionsStatusSync"))
    XCTAssertFalse(trackerSource.contains("unbindSupervisorNotifications"))
  }

  private func makeStore() -> HarnessMonitorStore {
    HarnessMonitorStore(
      daemonController: PreviewDaemonController(mode: .empty),
      voiceCapture: PreviewVoiceCaptureService(),
      daemonOwnership: .managed
    )
  }

  private func harnessSourceFile(named relativePath: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor-macos/Sources/HarnessMonitor")
      .appendingPathComponent(relativePath)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }
}
