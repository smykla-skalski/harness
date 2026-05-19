import Foundation
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
    let dismissedDecision = decision(id: "decision-dismissed", severity: .info, statusRaw: "dismissed")

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

  @Test("Overview presentation scopes session board items off main")
  func overviewPresentationScopesSessionBoardItems() async {
    let worker = TaskBoardOverviewPresentationWorker()
    let scoped = taskBoardItem(id: "session-item", status: .todo, sessionId: "sess-current")
    let other = taskBoardItem(id: "other-item", status: .todo, sessionId: "sess-other")

    let presentation = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [scoped, other],
        decisionItems: [],
        scopeSessionID: "sess-current"
      )
    )

    #expect(presentation.taskBoardItems.map(\.id) == ["session-item"])
    #expect(presentation.apiItems(in: .ready).map(\.id) == ["session-item"])
  }

  @Test("Lane strip sizing keeps the current minimum width until the board can expand")
  func laneStripSizingKeepsMinimumWidthUntilExpansion() {
    let sizing = TaskBoardLaneStripSizing(minColumnWidth: 288, spacing: 16)

    #expect(sizing.minimumWidth(for: 3) == 896)
    #expect(sizing.columnWidth(for: 760, columnCount: 3) == 288)
    #expect(sizing.resolvedWidth(for: 760, columnCount: 3) == 896)
  }

  @Test("Lane strip sizing shares extra board width equally across columns")
  func laneStripSizingSharesExtraWidthEqually() {
    let sizing = TaskBoardLaneStripSizing(minColumnWidth: 288, spacing: 16)
    let width = sizing.columnWidth(for: 1_120, columnCount: 3)

    #expect(abs(width - 362.6666666666667) < 0.001)
    #expect(sizing.resolvedWidth(for: 1_120, columnCount: 3) == 1_120)
  }

  @Test("Dispatch presentation filters host project types off main")
  func dispatchPresentationFiltersHostProjectTypes() async {
    let worker = TaskBoardOperationsDispatchPresentationWorker()
    let accepted = taskBoardItem(
      id: "swift",
      status: .todo,
      targetProjectTypes: ["swift"]
    )
    let rejected = taskBoardItem(
      id: "rust",
      status: .todo,
      targetProjectTypes: ["rust"]
    )

    let presentation = await worker.compute(
      input: TaskBoardOperationsDispatchPresentationInput(
        taskBoardItems: [accepted, rejected],
        localHostProjectTypes: ["swift"]
      )
    )

    #expect(presentation.dispatchableItems.map(\.id) == ["swift"])
    #expect(presentation.item(id: "swift")?.id == "swift")
    #expect(presentation.item(id: "rust") == nil)
    #expect(!presentation.didFilterOut)
  }

  @Test("Needs You lane preserves explicit inbox status for imported GitHub inbox items")
  func needsYouLanePreservesImportedGitHubInboxStatus() {
    let inboxItem = taskBoardItem(
      id: "github-example-repo-42",
      status: .todo,
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/repo#42",
          url: "https://github.com/example/repo/issues/42"
        )
      ],
      planning: TaskBoardPlanningState()
    )

    #expect(TaskBoardInboxLane.needsYou.taskBoardDropStatus(for: inboxItem) == .needsYou)
  }

  @Test("Needs You lane keeps plan-review semantics for manual items")
  func needsYouLaneKeepsPlanReviewForManualItems() {
    let manualItem = taskBoardItem(
      id: "board-only",
      status: .todo,
      planning: TaskBoardPlanningState(summary: "Review the plan")
    )

    #expect(TaskBoardInboxLane.needsYou.taskBoardDropStatus(for: manualItem) == .planReview)
  }

  @Test("Drop deduper suppresses duplicate successful drops until reset")
  func dropDeduperSuppressesDuplicateSuccessfulDropsUntilReset() {
    var deduper = TaskBoardDropDeduper<String>()
    var moves = 0

    #expect(
      deduper.perform("board-1|running") {
        moves += 1
        return true
      }
    )
    #expect(
      deduper.perform("board-1|running") {
        moves += 1
        return true
      }
    )
    #expect(moves == 1)

    deduper.reset()

    #expect(
      deduper.perform("board-1|running") {
        moves += 1
        return true
      }
    )
    #expect(moves == 2)
  }

  @Test("Drop deduper retries a key after an unsuccessful move")
  func dropDeduperRetriesKeyAfterUnsuccessfulMove() {
    var deduper = TaskBoardDropDeduper<String>()
    var attempts = 0

    #expect(
      !deduper.perform("board-1|running") {
        attempts += 1
        return false
      }
    )
    #expect(
      deduper.perform("board-1|running") {
        attempts += 1
        return true
      }
    )
    #expect(attempts == 2)
  }

  @Test("Lane metrics scale pill padding with font scale")
  func laneMetricsScalePillPaddingWithFontScale() {
    let regular = TaskBoardLaneMetrics(fontScale: 1)
    let large = TaskBoardLaneMetrics(fontScale: 1.8)

    #expect(large.pillHorizontalPadding > regular.pillHorizontalPadding)
    #expect(large.pillVerticalPadding > regular.pillVerticalPadding)
  }

  @Test("Overview metrics share scaled board spacing and padding")
  func overviewMetricsShareScaledBoardSpacingAndPadding() {
    let regular = TaskBoardOverviewMetrics(fontScale: 1)
    let large = TaskBoardOverviewMetrics(fontScale: 1.8)

    #expect(regular.operationsCardMinWidth >= 280)
    #expect(large.operationsCardMinWidth > regular.operationsCardMinWidth)
    #expect(large.operationsCardMaxWidth > regular.operationsCardMaxWidth)
    #expect(large.columnSpacing > regular.columnSpacing)
    #expect(large.boardVerticalPadding > regular.boardVerticalPadding)
    #expect(large.summaryPillHorizontalPadding > regular.summaryPillHorizontalPadding)
    #expect(large.summaryPillVerticalPadding > regular.summaryPillVerticalPadding)
  }

  private func inboxItem(
    taskID: String,
    status: TaskStatus = .inProgress
  ) -> TaskBoardInboxItem {
    let item = TaskBoardInboxItem(
      session: PreviewFixtures.summary,
      task: WorkItem(
        taskId: taskID,
        title: "Linked task",
        context: nil,
        severity: .medium,
        status: status,
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
    guard let item else {
      preconditionFailure("expected task board inbox item fixture")
    }
    return item
  }

  private func taskBoardItem(
    id: String,
    status: TaskBoardStatus,
    priority: TaskBoardPriority = .medium,
    targetProjectTypes: [String] = [],
    externalRefs: [TaskBoardExternalRef] = [],
    planning: TaskBoardPlanningState = TaskBoardPlanningState(),
    sessionId: String? = nil,
    workItemId: String? = nil,
    deletedAt: String? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item",
      body: "Body",
      status: status,
      priority: priority,
      tags: [],
      projectId: "project-1",
      targetProjectTypes: targetProjectTypes,
      agentMode: .interactive,
      externalRefs: externalRefs,
      planning: planning,
      workflow: nil,
      sessionId: sessionId,
      workItemId: workItemId,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: deletedAt
    )
  }

  private func decision(
    id: String,
    severity: DecisionSeverity,
    statusRaw: String = "open"
  ) -> Decision {
    let decision = Decision(
      id: id,
      severity: severity,
      ruleID: "rule-\(id)",
      sessionID: PreviewFixtures.summary.sessionId,
      agentID: nil,
      taskID: nil,
      summary: id,
      contextJSON: "{}",
      suggestedActionsJSON: "[]",
      createdAt: Date(timeIntervalSinceReferenceDate: 801_000_000)
    )
    decision.statusRaw = statusRaw
    return decision
  }
}
