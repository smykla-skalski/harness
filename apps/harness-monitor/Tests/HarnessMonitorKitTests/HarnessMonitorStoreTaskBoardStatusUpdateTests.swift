import Foundation
import Testing

@testable import HarnessMonitorKit

private actor TaskBoardStatusActionBarrier {
  private var entered = false
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func enterAndWait() async {
    entered = true
    enteredContinuation?.resume()
    enteredContinuation = nil
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { continuation in
      enteredContinuation = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

@MainActor
@Suite("Harness Monitor task-board status updates")
struct HarnessMonitorStoreTaskBoardStatusUpdateTests {
  @Test("Mixed card moves share one board action and execute both mutations")
  func mixedCardMovesExecuteBothMutations() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([taskBoardItem(id: "board-1", status: .todo)])
    let store = await selectedActionStore(client: client)
    let inboxTask = PreviewFixtures.tasks[0]

    let success = await store.updateTaskBoardCardStatuses(
      taskBoardUpdates: [
        TaskBoardItemStatusUpdate(id: "board-1", status: .inProgress)
      ],
      inboxUpdates: [
        TaskBoardInboxStatusUpdate(
          sessionID: PreviewFixtures.summary.sessionId,
          taskID: inboxTask.taskId,
          status: .awaitingReview
        )
      ]
    )

    #expect(success)
    #expect(
      client.recordedCalls() == [
        .updateTaskBoardItem(id: "board-1", status: .inProgress),
        .updateTask(
          sessionID: PreviewFixtures.summary.sessionId,
          taskID: inboxTask.taskId,
          status: .awaitingReview,
          note: nil,
          actor: "harness-app"
        ),
      ]
    )
    #expect(store.globalTaskBoardItems.first?.status == .inProgress)
    #expect(
      store.selectedSession?.tasks.first(where: { $0.taskId == inboxTask.taskId })?.status
        == .awaitingReview
    )
    #expect(store.currentSuccessFeedbackMessage == "Moved task board cards")
    #expect(store.isTaskBoardBusy == false)
  }

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

  @Test("Inbox move restores an overlapping session action owner")
  func inboxMoveRestoresOverlappingSessionActionOwner() async {
    let client = RecordingHarnessClient()
    let store = await selectedActionStore(client: client)
    let sessionID = PreviewFixtures.summary.sessionId
    let existingActionID = ActionID.createTask(sessionID: sessionID).key
    let barrier = TaskBoardStatusActionBarrier()
    async let existingAction: Bool = store.mutateSelectedSession(
      actionName: "Create task",
      actionID: existingActionID,
      using: client,
      sessionID: sessionID,
      mutation: {
        await barrier.enterAndWait()
        return PreviewFixtures.detail
      }
    )

    await barrier.waitUntilEntered()
    let success = await store.updateTaskBoardInboxStatuses([
      TaskBoardInboxStatusUpdate(
        sessionID: sessionID,
        taskID: PreviewFixtures.tasks[0].taskId,
        status: .awaitingReview
      )
    ])

    #expect(success)
    #expect(store.isSessionActionInFlight)
    #expect(store.inFlightActionID == existingActionID)

    await barrier.release()
    _ = await existingAction
    #expect(store.isSessionActionInFlight == false)
    #expect(store.inFlightActionID == nil)
  }

  @Test("Failed optimistic inbox move preserves a newer session snapshot")
  func failedOptimisticInboxMovePreservesNewerSessionSnapshot() async throws {
    let client = RecordingHarnessClient()
    client.configureMutationDelay(.milliseconds(200))
    client.configureTaskUpdateError(
      HarnessMonitorAPIError.server(code: 500, message: "move failed")
    )
    let store = await selectedActionStore(client: client)
    store.stopAllStreams()
    let movedTask = PreviewFixtures.tasks[0]
    let removedTask = PreviewFixtures.tasks[1]

    let mutation = Task { @MainActor in
      await store.updateTaskBoardInboxStatuses([
        TaskBoardInboxStatusUpdate(
          sessionID: PreviewFixtures.summary.sessionId,
          taskID: movedTask.taskId,
          status: .awaitingReview
        )
      ])
    }

    var optimisticDetail: SessionDetail?
    for _ in 0..<100 {
      if let detail = store.selectedSession,
        detail.tasks.first(where: { $0.taskId == movedTask.taskId })?.status == .awaitingReview
      {
        optimisticDetail = detail
        break
      }
      await Task.yield()
    }
    let currentDetail = try #require(optimisticDetail)
    let newerAgents = Array(currentDetail.agents.dropLast())
    let newerDetail = SessionDetail(
      session: currentDetail.session,
      agents: newerAgents,
      tasks: currentDetail.tasks.filter { $0.taskId != removedTask.taskId },
      signals: [],
      observer: currentDetail.observer,
      agentActivity: currentDetail.agentActivity
    )
    store.applySelectedSessionSnapshot(
      sessionID: PreviewFixtures.summary.sessionId,
      detail: newerDetail,
      timeline: store.timeline,
      timelineWindow: store.timelineWindow,
      clearBurstState: false,
      showingCachedData: store.isShowingCachedData,
      cancelPendingTimelineRefresh: false
    )

    let success = await mutation.value

    #expect(success == false)
    #expect(
      store.selectedSession?.tasks.first(where: { $0.taskId == movedTask.taskId })?.status
        == movedTask.status
    )
    #expect(
      store.selectedSession?.tasks.contains(where: { $0.taskId == removedTask.taskId }) == false
    )
    #expect(store.selectedSession?.agents == newerAgents)
    #expect(store.selectedSession?.signals.isEmpty == true)
  }

  @Test("Failed optimistic inbox move preserves a newer status for the same task")
  func failedOptimisticInboxMovePreservesNewerTaskStatus() async throws {
    let client = RecordingHarnessClient()
    client.configureMutationDelay(.milliseconds(200))
    client.configureTaskUpdateError(
      HarnessMonitorAPIError.server(code: 500, message: "move failed")
    )
    let store = await selectedActionStore(client: client)
    store.stopAllStreams()
    let movedTask = PreviewFixtures.tasks[0]

    let mutation = Task { @MainActor in
      await store.updateTaskBoardInboxStatuses([
        TaskBoardInboxStatusUpdate(
          sessionID: PreviewFixtures.summary.sessionId,
          taskID: movedTask.taskId,
          status: .awaitingReview
        )
      ])
    }

    var optimisticDetail: SessionDetail?
    for _ in 0..<100 {
      if let detail = store.selectedSession,
        detail.tasks.first(where: { $0.taskId == movedTask.taskId })?.status == .awaitingReview
      {
        optimisticDetail = detail
        break
      }
      await Task.yield()
    }
    let currentDetail = try #require(optimisticDetail)
    let newerDetail = SessionDetail(
      session: currentDetail.session,
      agents: currentDetail.agents,
      tasks: currentDetail.tasks.map { task in
        task.taskId == movedTask.taskId ? task.withOptimisticStatus(.done) : task
      },
      signals: currentDetail.signals,
      observer: currentDetail.observer,
      agentActivity: currentDetail.agentActivity
    )
    store.applySelectedSessionSnapshot(
      sessionID: PreviewFixtures.summary.sessionId,
      detail: newerDetail,
      timeline: store.timeline,
      timelineWindow: store.timelineWindow,
      clearBurstState: false,
      showingCachedData: store.isShowingCachedData,
      cancelPendingTimelineRefresh: false
    )

    let success = await mutation.value

    #expect(success == false)
    #expect(
      store.selectedSession?.tasks.first(where: { $0.taskId == movedTask.taskId })?.status == .done
    )
  }

  @Test("Optimistic move shows the new status before the network call resolves")
  func optimisticMoveShowsNewStatusBeforeNetworkResolves() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([taskBoardItem(id: "board-1", status: .todo)])
    client.configureMutationDelay(.milliseconds(200))
    let store = await makeBootstrappedStore(client: client)

    let mutation = Task { @MainActor in
      await store.updateTaskBoardItemStatuses([
        TaskBoardItemStatusUpdate(id: "board-1", status: .inProgress)
      ])
    }

    var observedOptimisticStatus: TaskBoardStatus?
    for _ in 0..<50 {
      if let status = store.globalTaskBoardItems.first(where: { $0.id == "board-1" })?.status,
        status == .inProgress
      {
        observedOptimisticStatus = status
        break
      }
      await Task.yield()
    }
    _ = await mutation.value

    #expect(observedOptimisticStatus == .inProgress)
    #expect(store.globalTaskBoardItems.first(where: { $0.id == "board-1" })?.status == .inProgress)
  }

  @Test("Optimistic move rolls back to the prior status on failure")
  func optimisticMoveRollsBackOnFailure() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([taskBoardItem(id: "board-1", status: .todo)])
    client.configureTaskBoardUpdateError(
      HarnessMonitorAPIError.server(code: 500, message: "boom")
    )
    let store = await makeBootstrappedStore(client: client)

    let success = await store.updateTaskBoardItemStatuses([
      TaskBoardItemStatusUpdate(id: "board-1", status: .inProgress)
    ])

    #expect(success == false)
    #expect(store.globalTaskBoardItems.first(where: { $0.id == "board-1" })?.status == .todo)
    #expect(store.currentFailureFeedbackMessage != nil)
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
