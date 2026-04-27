import SwiftData
import XCTest

@testable import HarnessMonitorKit

// MARK: - SupervisorLifecycleTests

/// Tests for `SupervisorLifecycle` and `HarnessMonitorStore+Supervisor` wiring.
///
/// The lifecycle class wraps `NSBackgroundActivityScheduler` and preference-driven
/// start/stop. Tests exercise:
/// - `startBackgroundActivity` schedules the activity and the tick fires.
/// - `stopBackgroundActivity` invalidates the scheduler and ticks stop.
/// - Preference key `supervisorRunInBackground` gates whether background activity starts.
/// - `startSupervisor`/`stopSupervisor` on the store create and tear down the full stack.
final class SupervisorLifecycleTests: XCTestCase {
  // MARK: - startBackgroundActivity / stopBackgroundActivity

  func test_startBackgroundActivitySchedulesActivity() async throws {
    let lifecycle = SupervisorLifecycle()
    UserDefaults.standard.set(true, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      )
    }
    lifecycle.startBackgroundActivity()
    defer { lifecycle.stopBackgroundActivity() }

    try await Task.sleep(for: .milliseconds(50))
    XCTAssertTrue(
      lifecycle.isBackgroundActivityScheduled,
      "Scheduler must be armed after startBackgroundActivity when preference is enabled"
    )
  }

  func test_startBackgroundActivityClampsToleranceBelowInterval() {
    let lifecycle = SupervisorLifecycle(interval: 10, tolerance: 30)
    UserDefaults.standard.set(true, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      )
      lifecycle.stopBackgroundActivity()
    }

    lifecycle.startBackgroundActivity()

    XCTAssertTrue(
      lifecycle.isBackgroundActivityScheduled,
      "Scheduler must still arm when requested tolerance exceeds interval"
    )
  }

  func test_stopBackgroundActivityIsIdempotent() {
    let lifecycle = SupervisorLifecycle()
    lifecycle.stopBackgroundActivity()
    lifecycle.stopBackgroundActivity()
    XCTAssertFalse(lifecycle.isBackgroundActivityScheduled)
  }

  func test_startFollowedByStopClearsScheduledFlag() {
    let lifecycle = SupervisorLifecycle()
    UserDefaults.standard.set(true, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      )
    }
    lifecycle.startBackgroundActivity()
    XCTAssertTrue(lifecycle.isBackgroundActivityScheduled)
    lifecycle.stopBackgroundActivity()
    XCTAssertFalse(lifecycle.isBackgroundActivityScheduled)
  }

  func test_startAfterStopRearmsScheduler() {
    let lifecycle = SupervisorLifecycle()
    UserDefaults.standard.set(true, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      )
    }
    lifecycle.startBackgroundActivity()
    lifecycle.stopBackgroundActivity()
    lifecycle.startBackgroundActivity()
    XCTAssertTrue(lifecycle.isBackgroundActivityScheduled)
    lifecycle.stopBackgroundActivity()
  }

  // MARK: - Background preference gate

  func test_startRespectsSupervisorRunInBackgroundFalse() {
    let lifecycle = SupervisorLifecycle()
    UserDefaults.standard.set(false, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      )
    }
    lifecycle.startBackgroundActivity()
    XCTAssertFalse(
      lifecycle.isBackgroundActivityScheduled,
      "Scheduler must not be armed when the background preference is disabled"
    )
    lifecycle.stopBackgroundActivity()
  }

  func test_startRespectsSupervisorRunInBackgroundTrue() {
    let lifecycle = SupervisorLifecycle()
    UserDefaults.standard.set(true, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      )
    }
    lifecycle.startBackgroundActivity()
    XCTAssertTrue(
      lifecycle.isBackgroundActivityScheduled,
      "Scheduler must be armed when the background preference is enabled"
    )
    lifecycle.stopBackgroundActivity()
  }

  func test_missingPreferenceDefaultsToDisabled() {
    let lifecycle = SupervisorLifecycle()
    UserDefaults.standard.removeObject(
      forKey: SupervisorPreferencesDefaults.runInBackgroundKey
    )
    lifecycle.startBackgroundActivity()
    XCTAssertFalse(
      lifecycle.isBackgroundActivityScheduled,
      "A missing preference should use the default (disabled)"
    )
    lifecycle.stopBackgroundActivity()
  }

  // MARK: - Tick callback wiring

  func test_forceTickInvokesOnTickCallback() async {
    let lifecycle = SupervisorLifecycle()
    let recorder = TickRecorder()
    lifecycle.onTick = { await recorder.recordTick() }

    await lifecycle.forceTick()

    let count = await recorder.count
    XCTAssertTrue(count > 0, "forceTick must invoke the onTick closure")
  }

  func test_onTickCallbackIsNilWhenNotSet() async {
    let lifecycle = SupervisorLifecycle()
    await lifecycle.forceTick()
  }

  func test_forceTickCanBeCalledMultipleTimes() async {
    let lifecycle = SupervisorLifecycle()
    let recorder = TickRecorder()
    lifecycle.onTick = { await recorder.recordTick() }

    await lifecycle.forceTick()
    await lifecycle.forceTick()
    await lifecycle.forceTick()

    let count = await recorder.count
    XCTAssertEqual(count, 3)
  }

  // MARK: - PreferencesDefaults constants

  func test_activityIdentifierIsStable() {
    XCTAssertEqual(
      SupervisorPreferencesDefaults.activityIdentifier,
      "io.harnessmonitor.supervisor"
    )
  }

  func test_runInBackgroundDefaultIsFalse() {
    XCTAssertFalse(SupervisorPreferencesDefaults.runInBackgroundDefault)
  }

  // MARK: - Store wiring

  @MainActor
  func test_startSupervisorThenStopDoesNotCrash() async {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    await store.stopSupervisor()
  }

  @MainActor
  func test_startSupervisorHonorsDisabledBackgroundPreference() async throws {
    UserDefaults.standard.set(false, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      )
    }

    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    await store.startSupervisor()
    defer { Task { await store.stopSupervisor() } }

    XCTAssertFalse(store.isSupervisorBackgroundActivityScheduledForTesting())
    XCTAssertFalse(store.isSupervisorAuditRetentionScheduledForTesting())
  }

  @MainActor
  func test_startSupervisorIsIdempotent() async {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    await store.startSupervisor()
    await store.stopSupervisor()
  }

  @MainActor
  func test_stopSupervisorBeforeStartDoesNotCrash() async {
    let store = HarnessMonitorStore.fixture()
    await store.stopSupervisor()
  }

  @MainActor
  func test_supervisorRunsOneTickOnDemand() async throws {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    defer { Task { await store.stopSupervisor() } }

    await store.runSupervisorTickForTesting()
  }

  @MainActor
  func test_runSupervisorTickPersistsAuditEventsWithLiveTickIDs() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    await store.startSupervisor()
    defer { Task { await store.stopSupervisor() } }

    await store.runSupervisorTickForTesting()

    let context = try XCTUnwrap(store.modelContext)
    let events = try context.fetch(FetchDescriptor<SupervisorEvent>())
    XCTAssertFalse(events.isEmpty)
    XCTAssertTrue(events.allSatisfy { $0.tickID != "executor" })
  }

  @MainActor
  func test_seededStuckAgentScenarioQueuesDecisionOnForcedTick() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    store.seedSupervisorScenarioForTesting(named: "stuck-agent")
    await store.startSupervisor()
    defer { Task { await store.stopSupervisor() } }

    await store.runSupervisorTickForTesting()
    try await Task.sleep(for: .milliseconds(100))

    let context = try XCTUnwrap(store.modelContext)
    let decisions = try context.fetch(FetchDescriptor<Decision>())
    let seededDecision = try XCTUnwrap(
      decisions.first(
        where: {
          $0.id == "stuck-agent:session-ui-stuck:agent-ui-stuck:task-ui-stuck"
        }
      )
    )
    XCTAssertEqual(seededDecision.severityRaw, DecisionSeverity.needsUser.rawValue)
    XCTAssertEqual(store.supervisorToolbarSlice.count, 1)
    XCTAssertEqual(store.supervisorToolbarSlice.maxSeverity, .needsUser)
  }

  @MainActor
  func test_startSupervisorWithPersistenceSchedulesAuditRetention() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    UserDefaults.standard.set(true, forKey: SupervisorPreferencesDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorPreferencesDefaults.runInBackgroundKey
      )
    }
    await store.startSupervisor()
    defer { Task { await store.stopSupervisor() } }

    XCTAssertTrue(store.isSupervisorAuditRetentionScheduledForTesting())
  }

  @MainActor
  func test_toolbarSliceReflectsInsertedDecision() async throws {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    defer { Task { await store.stopSupervisor() } }

    XCTAssertEqual(store.supervisorToolbarSlice.count, 0)

    try await store.insertDecisionForTesting(DecisionDraft.fixture(id: "d-toolbar-check"))
    try await Task.sleep(for: .milliseconds(100))

    XCTAssertGreaterThan(
      store.supervisorToolbarSlice.count,
      0,
      "Toolbar slice must reflect the inserted decision"
    )
  }

  @MainActor
  func test_badgeSyncReflectsInsertedAndDismissedDecision() async throws {
    let store = HarnessMonitorStore.fixture()
    let center = RecordingNotificationCenter()
    let notifications = HarnessMonitorUserNotificationController(center: center)
    store.bindSupervisorNotifications(notifications)
    await store.startSupervisor()
    defer { Task { await store.stopSupervisor() } }

    let decisionID = "d-badge-sync"
    try await store.insertDecisionForTesting(DecisionDraft.fixture(id: decisionID))
    try await waitForBadgeCounts([1], center: center)
    XCTAssertEqual(center.badgeCounts, [1])

    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)
    try await decisionStore.dismiss(id: decisionID)
    try await waitForBadgeCounts([1, 0], center: center)
    XCTAssertEqual(center.badgeCounts, [1, 0])
  }

  @MainActor
  func test_stopSupervisorClearsBadge() async throws {
    let store = HarnessMonitorStore.fixture()
    let center = RecordingNotificationCenter()
    let notifications = HarnessMonitorUserNotificationController(center: center)
    store.bindSupervisorNotifications(notifications)
    await store.startSupervisor()

    try await store.insertDecisionForTesting(DecisionDraft.fixture(id: "d-badge-stop"))
    try await waitForBadgeCounts([1], center: center)
    XCTAssertEqual(center.badgeCounts, [1])

    await store.stopSupervisor()

    XCTAssertEqual(center.badgeCounts, [1, 0])
  }

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

    XCTAssertFalse(store.isSupervisorBackgroundActivityScheduledForTesting())
    XCTAssertTrue(store.isSupervisorAuditRetentionScheduledForTesting())

    store.setSupervisorRunInBackgroundEnabled(false)
    XCTAssertFalse(store.isSupervisorBackgroundActivityScheduledForTesting())
    XCTAssertFalse(store.isSupervisorAuditRetentionScheduledForTesting())

    store.setSupervisorRunInBackgroundEnabled(true)
    XCTAssertFalse(store.isSupervisorBackgroundActivityScheduledForTesting())
    XCTAssertTrue(store.isSupervisorAuditRetentionScheduledForTesting())
  }

  @MainActor
  func test_setSupervisorQuietHoursWindowUpdatesRuntimeSuppression() async {
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
