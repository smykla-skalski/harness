import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board overview behavior")
struct TaskBoardOverviewBehaviorTests {
  @Test("Lane drop policy ignores empty and same-lane payloads")
  func laneDropPolicyIgnoresEmptyAndSameLanePayloads() {
    var moves: [(String, TaskBoardInboxLane)] = []
    let payload = TaskBoardItemDragPayload(itemID: "board-1", status: .todo)

    #expect(
      !TaskBoardLaneDropPolicy.moveFirstPayload([], to: .running) { itemID, lane in
        moves.append((itemID, lane))
        return true
      }
    )
    #expect(
      !TaskBoardLaneDropPolicy.moveFirstPayload([payload], to: .ready) { itemID, lane in
        moves.append((itemID, lane))
        return true
      }
    )
    #expect(moves.isEmpty)
  }

  @Test("Lane drop policy forwards first cross-lane payload only")
  func laneDropPolicyForwardsFirstCrossLanePayloadOnly() {
    var moves: [(String, TaskBoardInboxLane)] = []
    let first = TaskBoardItemDragPayload(itemID: "board-1", status: .todo)
    let second = TaskBoardItemDragPayload(itemID: "board-2", status: .blocked)

    #expect(
      TaskBoardLaneDropPolicy.moveFirstPayload([first, second], to: .running) { itemID, lane in
        moves.append((itemID, lane))
        return true
      }
    )
    #expect(moves.count == 1)
    #expect(moves.first?.0 == "board-1")
    #expect(moves.first?.1 == .running)
  }

  @Test("Lane drop policy returns move result")
  func laneDropPolicyReturnsMoveResult() {
    let payload = TaskBoardItemDragPayload(itemID: "board-1", status: .todo)

    #expect(
      !TaskBoardLaneDropPolicy.moveFirstPayload([payload], to: .running) { _, _ in
        false
      }
    )
  }

  @Test("Board-only items select management surface instead of opening linked task")
  func boardOnlyItemsSelectManagementSurface() {
    let item = taskBoardItem(id: "board-only", status: .todo)

    #expect(
      TaskBoardOverviewItemBehavior.selectionAction(
        for: item,
        selectedTaskBoardItemID: nil,
        inboxItems: []
      ) == .selectBoardItem
    )
    #expect(
      TaskBoardOverviewItemBehavior.selectionAction(
        for: item,
        selectedTaskBoardItemID: "board-only",
        inboxItems: []
      ) == .clearBoardSelection
    )
  }

  @Test("Linked board items open only when the session task is available")
  func linkedBoardItemsOpenOnlyWhenSessionTaskIsAvailable() {
    let item = taskBoardItem(
      id: "linked",
      status: .inProgress,
      sessionId: PreviewFixtures.summary.sessionId,
      workItemId: "task-linked"
    )

    #expect(
      TaskBoardOverviewItemBehavior.selectionAction(
        for: item,
        selectedTaskBoardItemID: nil,
        inboxItems: []
      ) == .openLinkedTask
    )
    #expect(
      TaskBoardOverviewItemBehavior.selectionAction(
        for: item,
        selectedTaskBoardItemID: nil,
        inboxItems: [inboxItem(taskID: "other-task")]
      ) == .selectBoardItem
    )
    #expect(
      TaskBoardOverviewItemBehavior.selectionAction(
        for: item,
        selectedTaskBoardItemID: nil,
        inboxItems: [inboxItem(taskID: "task-linked")]
      ) == .openLinkedTask
    )
  }

  @Test("Board-only Run Once and Evaluate requests carry board item identity")
  func boardOnlyRequestsCarryBoardItemIdentity() {
    let item = taskBoardItem(id: "board-only", status: .planReview)

    let runOnce = TaskBoardOverviewItemBehavior.runOnceRequest(for: item)
    let evaluation = TaskBoardOverviewItemBehavior.evaluationRequest(for: item)

    #expect(runOnce.itemId == "board-only")
    #expect(runOnce.status == .planReview)
    #expect(runOnce.dryRun == nil)
    #expect(runOnce.projectDir == nil)
    #expect(evaluation.itemId == "board-only")
    #expect(evaluation.status == .planReview)
    #expect(evaluation.dryRun == false)
  }

  private func inboxItem(taskID: String) -> TaskBoardInboxItem {
    let item = TaskBoardInboxItem(
      session: PreviewFixtures.summary,
      task: WorkItem(
        taskId: taskID,
        title: "Linked task",
        context: nil,
        severity: .medium,
        status: .inProgress,
        assignedTo: nil,
        createdAt: "2026-05-14T10:00:00Z",
        updatedAt: "2026-05-14T10:01:00Z",
        createdBy: nil,
        notes: [],
        suggestedFix: nil,
        source: .manual,
        blockedReason: nil,
        completedAt: nil,
        checkpointSummary: nil
      )
    )
    precondition(item != nil)
    return item!
  }

  private func taskBoardItem(
    id: String,
    status: TaskBoardStatus,
    sessionId: String? = nil,
    workItemId: String? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item",
      body: "Body",
      status: status,
      priority: .medium,
      tags: [],
      projectId: "project-1",
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: sessionId,
      workItemId: workItemId,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }
}
