import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board overview behavior")
struct TaskBoardOverviewBehaviorTests {
  @Test("Card drop plan rejects empty and same-lane payloads")
  func cardDropPlanRejectsEmptyAndSameLanePayloads() {
    let item = TaskBoardCardDragItem.api(itemID: "board-1", status: .todo)
    let payload = TaskBoardCardDragPayload(item: item)

    #expect(TaskBoardCardDropPlan.resolve([], to: .inProgress) == nil)
    #expect(TaskBoardCardDropPlan.resolve([payload], to: .todo) == nil)
  }

  @Test("Card drop plan keeps every selected card in visible order")
  func cardDropPlanKeepsEverySelectedCardInVisibleOrder() throws {
    let first = TaskBoardCardDragItem.api(itemID: "board-1", status: .todo)
    let second = TaskBoardCardDragItem.api(itemID: "board-2", status: .failed)
    let payload = TaskBoardCardDragPayload(primaryCardID: first.id, items: [first, second])

    let plan = try #require(TaskBoardCardDropPlan.resolve([payload], to: .inProgress))

    #expect(plan.items.map(\.id) == [first.id, second.id])
  }

  @Test("Card drop plan skips cards already in the destination")
  func cardDropPlanSkipsCardsAlreadyInDestination() throws {
    let stationary = TaskBoardCardDragItem.api(itemID: "board-1", status: .inProgress)
    let moving = TaskBoardCardDragItem.api(itemID: "board-2", status: .todo)
    let payload = TaskBoardCardDragPayload(
      primaryCardID: stationary.id,
      items: [stationary, moving]
    )

    let plan = try #require(TaskBoardCardDropPlan.resolve([payload], to: .inProgress))

    #expect(plan.items == [moving])
  }

  @Test("Card drop plan deduplicates repeated payloads")
  func cardDropPlanDeduplicatesRepeatedPayloads() throws {
    let item = TaskBoardCardDragItem.api(itemID: "board-1", status: .todo)
    let payload = TaskBoardCardDragPayload(item: item)

    let plan = try #require(
      TaskBoardCardDropPlan.resolve([payload, payload], to: .inProgress)
    )

    #expect(plan.items == [item])
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

    #expect(confirmation.title == "Dispatch Todo items?")
    #expect(confirmation.message.contains("current filter"))
  }

  @Test("Card drop plan rejects unknown inbox source lanes")
  func cardDropPlanRejectsUnknownInboxSourceLanes() {
    let item = TaskBoardCardDragItem.inbox(
      sessionID: "session-1",
      taskID: "task-1",
      status: .open,
      sourceLaneRawValue: "unknown"
    )

    #expect(
      TaskBoardCardDropPlan.resolve([TaskBoardCardDragPayload(item: item)], to: .inProgress)
        == nil
    )
  }

  @Test("Card drop plan rejects a destination unsupported by one selected card")
  func cardDropPlanRejectsDestinationUnsupportedByOneSelectedCard() {
    let boardItem = TaskBoardCardDragItem.api(itemID: "board-1", status: .todo)
    let inboxItem = TaskBoardCardDragItem.inbox(
      sessionID: "session-1",
      taskID: "task-1",
      status: .open,
      sourceLaneRawValue: TaskBoardInboxLane.todo.rawValue
    )
    let payload = TaskBoardCardDragPayload(
      primaryCardID: boardItem.id,
      items: [boardItem, inboxItem]
    )

    #expect(TaskBoardCardDropPlan.resolve([payload], to: .planning) == nil)
    #expect(TaskBoardCardDropPlan.resolve([payload], to: .inProgress) != nil)
  }

  @Test("Board-only Run Once and Evaluate requests carry board item identity")
  func boardOnlyRequestsCarryBoardItemIdentity() {
    let item = taskBoardItem(id: "board-only", status: .agenticReview)

    let runOnce = TaskBoardOverviewItemBehavior.runOnceRequest(for: item)
    let evaluation = TaskBoardOverviewItemBehavior.evaluationRequest(for: item)

    #expect(runOnce.itemId == "board-only")
    #expect(runOnce.status == .agenticReview)
    #expect(runOnce.dryRun == nil)
    #expect(runOnce.projectDir == nil)
    #expect(evaluation.itemId == "board-only")
    #expect(evaluation.status == .agenticReview)
    #expect(evaluation.dryRun == false)
  }

  @Test("Collapsed lane titles keep a consistent font size")
  func collapsedLaneTitlesKeepConsistentFontSize() throws {
    let source = try taskBoardSource("TaskBoardLaneUnifiedColumn.swift")
    let start = try #require(
      source.range(of: "private var collapsedTitle: some View {")?.lowerBound
    )
    let end = try #require(
      source.range(
        of: "private var collapsedTitleVerticalOffset",
        range: start..<source.endIndex
      )?.lowerBound
    )
    let collapsedTitleSource = String(source[start..<end])

    #expect(collapsedTitleSource.contains(".fixedSize(horizontal: true, vertical: false)"))
    #expect(!collapsedTitleSource.contains(".minimumScaleFactor"))
  }

  @Test("Overview presentation buckets task board lanes and decisions off main")
  @MainActor
  func overviewPresentationBucketsTaskBoardLanesAndDecisions() async {
    let worker = TaskBoardOverviewPresentationWorker()
    let ready = taskBoardItem(id: "ready", status: .todo, priority: .high)
    let needsYou = taskBoardItem(id: "needs-you", status: .humanRequired, priority: .critical)
    let deleted = taskBoardItem(id: "deleted", status: .failed, deletedAt: "2026-05-14T11:00:00Z")
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

    #expect(presentation.apiItems(in: .humanRequired).map(\.id) == ["needs-you"])
    #expect(presentation.apiItems(in: .todo).map(\.id) == ["ready"])
    #expect(presentation.apiItems(in: .failed).isEmpty)
    #expect(presentation.inboxItems(in: .inProgress).map(\.task.taskId) == ["running-inbox"])
    #expect(presentation.decisionIDs(in: .humanRequired) == ["decision-critical"])
    #expect(presentation.aggregateNeedsYouCount == 2)
    #expect(presentation.aggregateOpenCount == 4)
  }

  private func taskBoardSource(_ filename: String) throws -> String {
    let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let repoRoot =
      testsDirectory
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fileURL =
      repoRoot
      .appendingPathComponent("apps/harness-monitor/Sources/HarnessMonitorUIPreviewable")
      .appendingPathComponent("Views/TaskBoard")
      .appendingPathComponent(filename)
    return try String(contentsOf: fileURL, encoding: .utf8)
  }

}
