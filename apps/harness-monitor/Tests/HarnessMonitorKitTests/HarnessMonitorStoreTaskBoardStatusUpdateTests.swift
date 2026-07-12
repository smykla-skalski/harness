import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board status updates")
struct HarnessMonitorStoreTaskBoardStatusUpdateTests {
  @Test("Moving task board items batches updates before one dashboard refresh")
  func movingTaskBoardItemsBatchesUpdatesBeforeOneDashboardRefresh() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      taskBoardItem(id: "board-1", status: .todo),
      taskBoardItem(id: "board-2", status: .planning),
    ])
    let store = await makeBootstrappedStore(client: client)
    let baselineItemReads = client.readCallCount(.taskBoardItems(nil))

    let success = await store.updateTaskBoardItemStatuses([
      TaskBoardItemStatusUpdate(id: "board-1", status: .inProgress),
      TaskBoardItemStatusUpdate(id: "board-2", status: .inReview),
    ])

    let updateCalls = client.recordedCalls().filter {
      if case .updateTaskBoardItem = $0 { return true }
      return false
    }
    #expect(success)
    #expect(
      updateCalls == [
        .updateTaskBoardItem(id: "board-1", status: .inProgress),
        .updateTaskBoardItem(id: "board-2", status: .inReview),
      ]
    )
    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineItemReads + 1)
    #expect(
      Dictionary(uniqueKeysWithValues: store.globalTaskBoardItems.map { ($0.id, $0.status) })
        == ["board-1": .inProgress, "board-2": .inReview]
    )
    #expect(store.currentSuccessFeedbackMessage == "Moved task board items")
  }

  @Test("Moving session tasks applies one grouped mutation result")
  func movingSessionTasksAppliesOneGroupedMutationResult() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)
    let first = PreviewFixtures.tasks[0]
    let second = PreviewFixtures.tasks[1]

    let success = await store.updateTaskBoardInboxStatuses([
      TaskBoardInboxStatusUpdate(
        sessionID: PreviewFixtures.summary.sessionId,
        taskID: first.taskId,
        status: .awaitingReview
      ),
      TaskBoardInboxStatusUpdate(
        sessionID: PreviewFixtures.summary.sessionId,
        taskID: second.taskId,
        status: .awaitingReview
      ),
    ])

    #expect(success)
    #expect(
      client.recordedCalls() == [
        .updateTask(
          sessionID: PreviewFixtures.summary.sessionId,
          taskID: first.taskId,
          status: .awaitingReview,
          note: nil,
          actor: "harness-app"
        ),
        .updateTask(
          sessionID: PreviewFixtures.summary.sessionId,
          taskID: second.taskId,
          status: .awaitingReview,
          note: nil,
          actor: "harness-app"
        ),
      ]
    )
    #expect(store.selectedSession?.tasks.allSatisfy { $0.status == .awaitingReview } == true)
    #expect(store.currentSuccessFeedbackMessage == "Moved session tasks")
  }

  private func taskBoardItem(id: String, status: TaskBoardStatus) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item",
      body: "Body",
      status: status,
      priority: .high,
      tags: ["automation"],
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
}
