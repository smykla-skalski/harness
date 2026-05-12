import SwiftData
import XCTest

@testable import HarnessMonitorKit

extension SupervisorLifecycleTests {
  @MainActor
  func testStartSupervisorThenStopDoesNotCrash() async {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    await store.stopSupervisor()
  }

  @MainActor
  func testSupervisorRuntimeStateStartsStopped() {
    let store = HarnessMonitorStore.fixture()

    XCTAssertEqual(store.supervisorRuntimeState, .stopped)
  }

  @MainActor
  func testSupervisorRuntimeStateTracksStartAndStop() async {
    let store = HarnessMonitorStore.fixture()

    await store.startSupervisor()
    XCTAssertEqual(store.supervisorRuntimeState, .running)

    await store.stopSupervisor()
    XCTAssertEqual(store.supervisorRuntimeState, .stopped)
  }

  @MainActor
  func testSupervisorCheckNowStartsSupervisorWhenStopped() async {
    let store = HarnessMonitorStore.fixture()

    await store.requestSupervisorCheckNow()
    addTeardownBlock { await store.stopSupervisor() }

    XCTAssertEqual(store.supervisorRuntimeState, .running)
  }

  @MainActor
  func testStartSupervisorHonorsDisabledBackgroundPreference() async throws {
    UserDefaults.standard.set(false, forKey: SupervisorSettingsDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorSettingsDefaults.runInBackgroundKey
      )
    }

    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    XCTAssertFalse(store.isSupervisorBackgroundActivityScheduledForTesting())
    XCTAssertFalse(store.isSupervisorAuditRetentionScheduledForTesting())
  }

  @MainActor
  func testStartSupervisorIsIdempotent() async {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    await store.startSupervisor()
    await store.stopSupervisor()
  }

  @MainActor
  func testStopSupervisorBeforeStartDoesNotCrash() async {
    let store = HarnessMonitorStore.fixture()
    await store.stopSupervisor()
  }

  @MainActor
  func testSupervisorRunsOneTickOnDemand() async throws {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    await store.runSupervisorTickForTesting()
  }

  @MainActor
  func testRunSupervisorTickPersistsAuditEventsWithLiveTickIDs() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    await store.runSupervisorTickForTesting()

    let context = try XCTUnwrap(store.modelContext)
    let events = try context.fetch(FetchDescriptor<SupervisorEvent>())
    XCTAssertFalse(events.isEmpty)
    XCTAssertTrue(events.allSatisfy { $0.tickID != "executor" })
  }

  @MainActor
  func testRunSupervisorTickPublishesLiveTickSnapshotToStore() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    let initialRefreshTick = store.supervisorLiveTickRefreshTick

    await store.runSupervisorTickForTesting()

    let liveTick = await store.supervisorLiveTickSnapshot()
    XCTAssertGreaterThan(store.supervisorLiveTickRefreshTick, initialRefreshTick)
    XCTAssertNotNil(liveTick.lastSnapshotID)
  }

  @MainActor
  func testSeededStuckAgentScenarioQueuesDecisionOnForcedTick() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    await store.seedSupervisorScenarioForTesting(named: "stuck-agent")
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

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
  func testStartSupervisorWithPersistenceSchedulesAuditRetention() async throws {
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
  }

  @MainActor
  func testBackgroundLifecycleDoesNotDriveProductionPolicyTicks() async throws {
    let store = try await HarnessMonitorStore.fixture(sessions: .twoActiveSessions)
    UserDefaults.standard.set(true, forKey: SupervisorSettingsDefaults.runInBackgroundKey)
    defer {
      UserDefaults.standard.removeObject(
        forKey: SupervisorSettingsDefaults.runInBackgroundKey
      )
    }
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    await store.runSupervisorTickForTesting()
    let refreshTick = store.supervisorLiveTickRefreshTick

    await store.forceSupervisorBackgroundActivityTickForTesting()
    try await Task.sleep(for: .milliseconds(50))

    XCTAssertEqual(
      store.supervisorLiveTickRefreshTick,
      refreshTick,
      "background lifecycle must not be wired as a second production policy tick source"
    )
  }

  @MainActor
  func testToolbarSliceReflectsInsertedDecision() async throws {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

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
  func testBadgeSyncReflectsInsertedAndDismissedDecision() async throws {
    let store = HarnessMonitorStore.fixture()
    let center = RecordingNotificationCenter()
    let notifications = HarnessMonitorUserNotificationController(center: center)
    store.bindSupervisorNotifications(notifications)
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

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
  func testPendingDecisionsBadgeSyncReflectsInsertedAndDismissedDecision() async throws {
    let store = HarnessMonitorStore.fixture()
    let recorder = PendingDecisionsBadgeSyncRecorder()
    store.bindPendingDecisionsBadgeSync { count in
      recorder.record(count)
    }
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    let decisionID = "d-pending-badge-sync"
    try await store.insertDecisionForTesting(DecisionDraft.fixture(id: decisionID))
    try await waitForPendingDecisionBadgeCounts([0, 1], recorder: recorder)
    XCTAssertEqual(recorder.counts, [0, 1])

    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)
    try await decisionStore.dismiss(id: decisionID)
    try await waitForPendingDecisionBadgeCounts([0, 1, 0], recorder: recorder)
    XCTAssertEqual(recorder.counts, [0, 1, 0])
  }

  @MainActor
  func testPendingDecisionsStatusSyncReflectsInsertedAndDismissedDecision() async throws {
    let store = HarnessMonitorStore.fixture()
    let recorder = PendingDecisionsStatusSyncRecorder()
    store.bindPendingDecisionsStatusSync { count, severity in
      recorder.record(count: count, severity: severity)
    }
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    let decisionID = "d-pending-status-sync"
    try await store.insertDecisionForTesting(
      DecisionDraft.fixture(id: decisionID, severity: .critical)
    )
    try await waitForPendingDecisionStatusUpdates(
      [
        PendingDecisionsStatusSyncUpdate(count: 0, severity: nil),
        PendingDecisionsStatusSyncUpdate(count: 1, severity: .critical),
      ],
      recorder: recorder
    )
    XCTAssertEqual(
      recorder.updates,
      [
        PendingDecisionsStatusSyncUpdate(count: 0, severity: nil),
        PendingDecisionsStatusSyncUpdate(count: 1, severity: .critical),
      ]
    )

    let decisionStore = try XCTUnwrap(store.supervisorDecisionStore)
    try await decisionStore.dismiss(id: decisionID)
    try await waitForPendingDecisionStatusUpdates(
      [
        PendingDecisionsStatusSyncUpdate(count: 0, severity: nil),
        PendingDecisionsStatusSyncUpdate(count: 1, severity: .critical),
        PendingDecisionsStatusSyncUpdate(count: 0, severity: nil),
      ],
      recorder: recorder
    )
    XCTAssertEqual(
      recorder.updates,
      [
        PendingDecisionsStatusSyncUpdate(count: 0, severity: nil),
        PendingDecisionsStatusSyncUpdate(count: 1, severity: .critical),
        PendingDecisionsStatusSyncUpdate(count: 0, severity: nil),
      ]
    )
  }

  @MainActor
  func testLatePendingDecisionBindingsPublishCurrentSupervisorSnapshot() async throws {
    let store = HarnessMonitorStore.fixture()
    await store.startSupervisor()
    addTeardownBlock { await store.stopSupervisor() }

    try await store.insertDecisionForTesting(
      DecisionDraft.fixture(id: "d-late-pending-sync", severity: .critical)
    )
    try await waitForSupervisorOpenDecisionCount(1, store: store)

    let badgeRecorder = PendingDecisionsBadgeSyncRecorder()
    store.bindPendingDecisionsBadgeSync { count in
      badgeRecorder.record(count)
    }
    XCTAssertEqual(badgeRecorder.counts, [1])

    let statusRecorder = PendingDecisionsStatusSyncRecorder()
    store.bindPendingDecisionsStatusSync { count, severity in
      statusRecorder.record(count: count, severity: severity)
    }
    XCTAssertEqual(
      statusRecorder.updates,
      [
        PendingDecisionsStatusSyncUpdate(count: 1, severity: .critical)
      ]
    )
  }

  @MainActor
  func testStopSupervisorClearsBadge() async throws {
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
  func testStopSupervisorClearsPendingDecisionsBadgeSync() async throws {
    let store = HarnessMonitorStore.fixture()
    let recorder = PendingDecisionsBadgeSyncRecorder()
    store.bindPendingDecisionsBadgeSync { count in
      recorder.record(count)
    }
    await store.startSupervisor()

    try await store.insertDecisionForTesting(DecisionDraft.fixture(id: "d-pending-badge-stop"))
    try await waitForPendingDecisionBadgeCounts([0, 1], recorder: recorder)
    XCTAssertEqual(recorder.counts, [0, 1])

    await store.stopSupervisor()

    XCTAssertEqual(recorder.counts, [0, 1, 0])
  }

  @MainActor
  func testStopSupervisorClearsPendingDecisionsStatusSync() async throws {
    let store = HarnessMonitorStore.fixture()
    let recorder = PendingDecisionsStatusSyncRecorder()
    store.bindPendingDecisionsStatusSync { count, severity in
      recorder.record(count: count, severity: severity)
    }
    await store.startSupervisor()

    try await store.insertDecisionForTesting(
      DecisionDraft.fixture(id: "d-pending-status-stop", severity: .warn)
    )
    try await waitForPendingDecisionStatusUpdates(
      [
        PendingDecisionsStatusSyncUpdate(count: 0, severity: nil),
        PendingDecisionsStatusSyncUpdate(count: 1, severity: .warn),
      ],
      recorder: recorder
    )
    XCTAssertEqual(
      recorder.updates,
      [
        PendingDecisionsStatusSyncUpdate(count: 0, severity: nil),
        PendingDecisionsStatusSyncUpdate(count: 1, severity: .warn),
      ]
    )

    await store.stopSupervisor()

    XCTAssertEqual(
      recorder.updates,
      [
        PendingDecisionsStatusSyncUpdate(count: 0, severity: nil),
        PendingDecisionsStatusSyncUpdate(count: 1, severity: .warn),
        PendingDecisionsStatusSyncUpdate(count: 0, severity: nil),
      ]
    )
  }
}
