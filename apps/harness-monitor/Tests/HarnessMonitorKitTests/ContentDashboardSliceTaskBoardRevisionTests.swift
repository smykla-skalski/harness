import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("ContentDashboardSlice task-board revision")
struct ContentDashboardSliceTaskBoardRevisionTests {
  @Test("Revision bumps only when taskBoardItems actually changes")
  func revisionBumpsOnItemsChange() {
    let slice = HarnessMonitorStore.ContentDashboardSlice()
    let itemA = taskBoardItem(id: "board-1", status: .todo)
    let itemB = taskBoardItem(id: "board-1", status: .inProgress)

    slice.apply(HarnessMonitorStore.ContentDashboardState(taskBoardItems: [itemA]))
    #expect(slice.taskBoardSnapshotRevision == 1)

    slice.apply(HarnessMonitorStore.ContentDashboardState(taskBoardItems: [itemA]))
    #expect(slice.taskBoardSnapshotRevision == 1)

    slice.apply(HarnessMonitorStore.ContentDashboardState(taskBoardItems: [itemB]))
    #expect(slice.taskBoardSnapshotRevision == 2)
  }

  @Test("Revision bumps only when taskBoardOrchestratorStatus actually changes")
  func revisionBumpsOnOrchestratorStatusChange() {
    let slice = HarnessMonitorStore.ContentDashboardSlice()
    let statusA = orchestratorStatus(running: false)
    let statusB = orchestratorStatus(running: true)

    slice.apply(HarnessMonitorStore.ContentDashboardState(taskBoardOrchestratorStatus: statusA))
    #expect(slice.taskBoardSnapshotRevision == 1)

    slice.apply(HarnessMonitorStore.ContentDashboardState(taskBoardOrchestratorStatus: statusA))
    #expect(slice.taskBoardSnapshotRevision == 1)

    slice.apply(HarnessMonitorStore.ContentDashboardState(taskBoardOrchestratorStatus: statusB))
    #expect(slice.taskBoardSnapshotRevision == 2)
  }

  @Test("Revision does not bump for unrelated field changes")
  func revisionStableAcrossUnrelatedChange() {
    let slice = HarnessMonitorStore.ContentDashboardSlice()
    let item = taskBoardItem(id: "board-1", status: .todo)

    slice.apply(HarnessMonitorStore.ContentDashboardState(isBusy: false, taskBoardItems: [item]))
    #expect(slice.taskBoardSnapshotRevision == 1)

    slice.apply(HarnessMonitorStore.ContentDashboardState(isBusy: true, taskBoardItems: [item]))
    #expect(slice.taskBoardSnapshotRevision == 1)
    #expect(slice.isBusy)
  }

  private func taskBoardItem(id: String, status: TaskBoardStatus) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item",
      body: "Body",
      status: status,
      priority: .high,
      tags: [],
      projectId: "project-1",
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }

  private func orchestratorStatus(running: Bool) -> TaskBoardOrchestratorStatus {
    TaskBoardOrchestratorStatus(
      enabled: true,
      running: running,
      settings: TaskBoardOrchestratorSettings(policyVersion: "v1")
    )
  }
}
