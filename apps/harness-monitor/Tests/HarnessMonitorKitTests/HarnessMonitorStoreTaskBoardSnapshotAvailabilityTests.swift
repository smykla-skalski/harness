import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board snapshot availability")
struct TaskBoardSnapshotAvailabilityTests {
  @Test("Unavailable item refreshes preserve unknown snapshot state")
  func unavailableItemRefreshPreservesUnknownSnapshotState() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    store.applyTaskBoardDashboardSnapshot(snapshot(items: nil))

    #expect(!store.globalTaskBoardItemsSnapshotAvailable)
    #expect(!store.contentUI.dashboard.taskBoardItemsSnapshotAvailable)
  }

  @Test("A successful empty item refresh makes repository scope authoritative")
  func successfulEmptyItemRefreshMakesRepositoryScopeAuthoritative() {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

    store.applyTaskBoardDashboardSnapshot(snapshot(items: []))

    #expect(store.globalTaskBoardItemsSnapshotAvailable)
    #expect(store.contentUI.dashboard.taskBoardItemsSnapshotAvailable)
  }

  private func snapshot(
    items: [TaskBoardItem]?
  ) -> HarnessMonitorStore.TaskBoardRefreshSnapshot {
    HarnessMonitorStore.TaskBoardRefreshSnapshot(
      items: HarnessMonitorStore.TaskBoardSnapshotLoad(
        measured: items.map {
          HarnessMonitorStore.MeasuredOperation(value: $0, latencyMs: 0)
        }
      ),
      orchestratorStatus: HarnessMonitorStore.TaskBoardSnapshotLoad<
        TaskBoardOrchestratorStatus?
      >(measured: nil),
      projects: HarnessMonitorStore.TaskBoardSnapshotLoad<[TaskBoardProjectSummary]>(
        measured: nil
      ),
      stepModeConfirmationRevision: 0
    )
  }
}
