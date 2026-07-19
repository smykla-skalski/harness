import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board automation state")
struct HarnessMonitorStoreTaskBoardAutomationTests {
  @Test("Snapshot merge preserves the highest revision")
  func snapshotMergePreservesHighestRevision() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    store.mergeTaskBoardAutomationSnapshot(snapshot(revision: 7))
    store.mergeTaskBoardAutomationSnapshot(snapshot(revision: 6))

    #expect(store.globalTaskBoardAutomationSnapshot?.revision == 7)

    store.mergeTaskBoardAutomationSnapshot(snapshot(revision: 8))
    #expect(store.globalTaskBoardAutomationSnapshot?.revision == 8)
  }

  @Test("Snapshot merge uses observation time to order equal revisions")
  func snapshotMergeOrdersEqualRevisionObservations() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    store.mergeTaskBoardAutomationSnapshot(
      snapshot(revision: 7, observedAt: "2026-07-19T12:01:00Z")
    )
    store.mergeTaskBoardAutomationSnapshot(
      snapshot(revision: 7, observedAt: "2026-07-19T12:00:00Z")
    )
    #expect(store.globalTaskBoardAutomationSnapshot?.observedAt == "2026-07-19T12:01:00Z")

    store.mergeTaskBoardAutomationSnapshot(
      snapshot(revision: 7, observedAt: "2026-07-19T12:02:00Z")
    )
    #expect(store.globalTaskBoardAutomationSnapshot?.observedAt == "2026-07-19T12:02:00Z")
  }

  @Test("Disconnect keeps embedded cached status from reviving automation controls")
  func offlineTransitionClearsAutomationStatus() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    let automation = snapshot(revision: 3)
    store.connectionState = .online
    store.globalTaskBoardOrchestratorStatus = status(automation: automation)
    store.mergeTaskBoardAutomationSnapshot(automation)
    #expect(store.contentUI.dashboard.taskBoardAutomationSnapshot?.revision == 3)

    store.connectionState = .offline("daemon unavailable")

    #expect(store.globalTaskBoardAutomationSnapshot == nil)
    #expect(store.contentUI.dashboard.taskBoardAutomationSnapshot == nil)

    store.connectionState = .online
    #expect(store.globalTaskBoardOrchestratorStatus?.automation?.revision == 3)
    #expect(store.contentUI.dashboard.taskBoardAutomationSnapshot == nil)

    store.applyTaskBoardDashboardSnapshot(
      HarnessMonitorStore.TaskBoardRefreshSnapshot(
        items: HarnessMonitorStore.TaskBoardSnapshotLoad<[TaskBoardItem]>(measured: nil),
        orchestratorStatus: HarnessMonitorStore.TaskBoardSnapshotLoad(measured: nil),
        stepModeConfirmationRevision: 0
      )
    )
    #expect(store.globalTaskBoardAutomationSnapshot == nil)
    #expect(store.contentUI.dashboard.taskBoardAutomationSnapshot == nil)
  }

  @Test("Persisted task-board status omits the ephemeral automation snapshot")
  func persistedStatusOmitsAutomationSnapshot() throws {
    let cached = try CachedTaskBoardSnapshot.make(
      items: [],
      orchestratorStatus: status(automation: snapshot(revision: 4))
    )

    #expect(try cached.decodedOrchestratorStatus()?.automation == nil)
  }

  @Test("Automation observations do not invalidate the task-board snapshot")
  func automationObservationsUseDedicatedDashboardState() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
    store.globalTaskBoardOrchestratorStatus = status(automation: snapshot(revision: 3))
    store.mergeTaskBoardAutomationSnapshot(snapshot(revision: 3))
    let taskBoardRevision = store.contentUI.dashboard.taskBoardSnapshotRevision

    store.globalTaskBoardOrchestratorStatus = status(automation: snapshot(revision: 4))
    store.mergeTaskBoardAutomationSnapshot(snapshot(revision: 4))

    #expect(store.contentUI.dashboard.taskBoardSnapshotRevision == taskBoardRevision)
    #expect(store.contentUI.dashboard.taskBoardOrchestratorStatus?.automation == nil)
    #expect(store.contentUI.dashboard.taskBoardAutomationSnapshot?.revision == 4)
  }

  private func snapshot(
    revision: UInt64,
    observedAt: String = "2026-07-19T12:00:00Z"
  ) -> TaskBoardAutomationSnapshot {
    TaskBoardAutomationSnapshot(
      revision: revision,
      desiredMode: .off,
      admissionState: .stopped,
      effectiveState: .idle,
      observedAt: observedAt,
      heartbeatAt: "2026-07-19T12:00:00Z",
      settingsRevision: 1,
      policyRevision: 1,
      queue: TaskBoardAutomationQueueSummary()
    )
  }

  private func status(
    automation: TaskBoardAutomationSnapshot?
  ) -> TaskBoardOrchestratorStatus {
    TaskBoardOrchestratorStatus(
      enabled: false,
      running: false,
      automation: automation,
      settings: TaskBoardOrchestratorSettings(policyVersion: "policy-v1")
    )
  }
}
