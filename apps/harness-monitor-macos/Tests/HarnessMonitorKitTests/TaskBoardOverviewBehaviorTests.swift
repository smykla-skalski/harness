import Foundation
import SwiftUI
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

    #expect(TaskBoardOverviewItemBehavior.selectionAction(for: item) == .selectBoardItem)
    #expect(TaskBoardOverviewItemBehavior.selectionAction(for: item) == .selectBoardItem)
  }

  @Test("Linked board items open directly without inbox snapshot state")
  func linkedBoardItemsOpenDirectlyWithoutInboxSnapshotState() {
    let item = taskBoardItem(
      id: "linked",
      status: .inProgress,
      sessionId: PreviewFixtures.summary.sessionId,
      workItemId: "task-linked"
    )

    #expect(TaskBoardOverviewItemBehavior.selectionAction(for: item) == .openLinkedTask)
  }

  @Test("Dispatch confirmation prefers the targeted board item title")
  func dispatchConfirmationPrefersTargetedBoardItemTitle() {
    let confirmation = TaskBoardDispatchConfirmationPresentation(
      request: TaskBoardDispatchRequest(itemId: "board-1", dryRun: false),
      itemTitle: "Board item"
    )

    #expect(confirmation.title == "Dispatch Board item?")
    #expect(confirmation.message.contains("selected board item"))
  }

  @Test("Dispatch confirmation falls back to the status filter title")
  func dispatchConfirmationFallsBackToStatusFilterTitle() {
    let confirmation = TaskBoardDispatchConfirmationPresentation(
      request: TaskBoardDispatchRequest(status: .todo, dryRun: false),
      itemTitle: nil
    )

    #expect(confirmation.title == "Dispatch Ready items?")
    #expect(confirmation.message.contains("current filter"))
  }

  @Test("Inbox drop policy ignores unknown source lane payloads")
  func inboxDropPolicyIgnoresUnknownSourceLanePayloads() throws {
    let payload = try JSONDecoder().decode(
      TaskBoardInboxItemDragPayload.self,
      from: Data(
        """
        {
          "sessionID": "sess-1",
          "taskID": "task-1",
          "status": "open",
          "laneRawValue": "unknown"
        }
        """.utf8
      )
    )

    #expect(
      !TaskBoardInboxDropPolicy.moveFirstPayload([payload], to: .running) { _, _ in
        true
      }
    )
  }

  @Test("Inbox drop policy forwards first cross-lane payload only")
  func inboxDropPolicyForwardsFirstCrossLanePayloadOnly() {
    var moves: [(String, TaskBoardInboxLane)] = []
    let first = TaskBoardInboxItemDragPayload(
      sessionID: "sess-1",
      taskID: "task-1",
      status: .open,
      lane: .ready
    )
    let second = TaskBoardInboxItemDragPayload(
      sessionID: "sess-2",
      taskID: "task-2",
      status: .blocked,
      lane: .blocked
    )

    #expect(
      TaskBoardInboxDropPolicy.moveFirstPayload([first, second], to: .running) { payload, lane in
        moves.append((payload.taskID, lane))
        return true
      }
    )
    #expect(moves.count == 1)
    #expect(moves.first?.0 == "task-1")
    #expect(moves.first?.1 == .running)
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

  @Test("Overview presentation buckets task board lanes and decisions off main")
  @MainActor
  func overviewPresentationBucketsTaskBoardLanesAndDecisions() async {
    let worker = TaskBoardOverviewPresentationWorker()
    let ready = taskBoardItem(id: "ready", status: .todo, priority: .high)
    let needsYou = taskBoardItem(id: "needs-you", status: .needsYou, priority: .critical)
    let deleted = taskBoardItem(id: "deleted", status: .blocked, deletedAt: "2026-05-14T11:00:00Z")
    let inbox = inboxItem(taskID: "running-inbox", status: .inProgress)
    let criticalDecision = decision(id: "decision-critical", severity: .critical)
    let dismissedDecision = decision(
      id: "decision-dismissed", severity: .info, statusRaw: "dismissed")

    let presentation = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(items: [inbox]),
        taskBoardItems: [ready, deleted, needsYou],
        decisionItems: [criticalDecision, dismissedDecision].map(DecisionPresentationItem.init),
        scopeSessionID: nil
      )
    )

    #expect(presentation.apiItems(in: .needsYou).map(\.id) == ["needs-you"])
    #expect(presentation.apiItems(in: .ready).map(\.id) == ["ready"])
    #expect(presentation.apiItems(in: .blocked).isEmpty)
    #expect(presentation.inboxItems(in: .running).map(\.task.taskId) == ["running-inbox"])
    #expect(presentation.decisionIDs(in: .needsYou) == ["decision-critical"])
    #expect(presentation.aggregateNeedsYouCount == 2)
    #expect(presentation.aggregateOpenCount == 4)
  }

}
