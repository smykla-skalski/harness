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

  func test_missingPreferenceDefaultsToEnabled() {
    let lifecycle = SupervisorLifecycle()
    UserDefaults.standard.removeObject(
      forKey: SupervisorPreferencesDefaults.runInBackgroundKey
    )
    lifecycle.startBackgroundActivity()
    XCTAssertTrue(
      lifecycle.isBackgroundActivityScheduled,
      "A missing preference should use the default (enabled)"
    )
    lifecycle.stopBackgroundActivity()
  }

  // MARK: - Tick callback wiring

  func test_forceTickInvokesOnTickCallback() {
    let lifecycle = SupervisorLifecycle()
    var called = false
    lifecycle.onTick = { called = true }

    lifecycle.forceTick()

    XCTAssertTrue(called, "forceTick must invoke the onTick closure")
  }

  func test_onTickCallbackIsNilWhenNotSet() {
    let lifecycle = SupervisorLifecycle()
    lifecycle.forceTick()
  }

  func test_forceTickCanBeCalledMultipleTimes() {
    let lifecycle = SupervisorLifecycle()
    var count = 0
    lifecycle.onTick = { count += 1 }

    lifecycle.forceTick()
    lifecycle.forceTick()
    lifecycle.forceTick()

    XCTAssertEqual(count, 3)
  }

  // MARK: - PreferencesDefaults constants

  func test_activityIdentifierIsStable() {
    XCTAssertEqual(
      SupervisorPreferencesDefaults.activityIdentifier,
      "io.harnessmonitor.supervisor"
    )
  }

  func test_runInBackgroundDefaultIsTrue() {
    XCTAssertTrue(SupervisorPreferencesDefaults.runInBackgroundDefault)
  }

  // MARK: - Store wiring

  @MainActor
  func test_startSupervisorThenStopDoesNotCrash() async {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    await store.stopSupervisor()
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
  func test_setSupervisorRunInBackgroundEnabledStopsAndStartsScheduler() async {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    defer { Task { await store.stopSupervisor() } }

    XCTAssertTrue(store.isSupervisorBackgroundActivityScheduledForTesting())

    store.setSupervisorRunInBackgroundEnabled(false)
    XCTAssertFalse(store.isSupervisorBackgroundActivityScheduledForTesting())

    store.setSupervisorRunInBackgroundEnabled(true)
    XCTAssertTrue(store.isSupervisorBackgroundActivityScheduledForTesting())
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
