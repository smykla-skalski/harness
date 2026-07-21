import Foundation
import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@MainActor
extension TaskBoardOverviewBehaviorTests {
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
    #expect(presentation.apiItems(in: .todo).map(\.id) == ["session-item"])
  }

  @Test("Umbrella items group under the umbrella lane regardless of status, even once done")
  func umbrellaItemsGroupUnderUmbrellaLaneRegardlessOfStatus() async {
    let worker = TaskBoardOverviewPresentationWorker()
    let openUmbrella = taskBoardItem(id: "umbrella-open", status: .todo, kind: .umbrella)
    let closedUmbrella = taskBoardItem(id: "umbrella-closed", status: .done, kind: .umbrella)
    let plainTodo = taskBoardItem(id: "plain-todo", status: .todo, kind: .task)

    let presentation = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [openUmbrella, closedUmbrella, plainTodo],
        decisionItems: [],
        scopeSessionID: nil
      )
    )

    #expect(
      Set(presentation.apiItems(in: .umbrella).map(\.id))
        == ["umbrella-open", "umbrella-closed"]
    )
    #expect(presentation.apiItems(in: .todo).map(\.id) == ["plain-todo"])
  }

  @Test("A closed umbrella counts once, as done, never also as open")
  func closedUmbrellaCountsOnceAsDoneNeverAlsoAsOpen() async {
    let worker = TaskBoardOverviewPresentationWorker()
    let closedUmbrella = taskBoardItem(id: "umbrella-closed", status: .done, kind: .umbrella)

    let presentation = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [closedUmbrella],
        decisionItems: [],
        scopeSessionID: nil
      )
    )

    #expect(presentation.aggregateDoneCount == 1)
    #expect(presentation.aggregateOpenCount == 0)
  }

  @Test("Step Mode target is the top Todo item and never another lane")
  func stepModeTargetIsTopTodoItem() async {
    let worker = TaskBoardOverviewPresentationWorker()
    let backlog = taskBoardItem(id: "backlog-item", status: .backlog)
    let todo = taskBoardItem(id: "ready", status: .todo)

    let presentation = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [backlog, todo],
        decisionItems: [],
        scopeSessionID: nil
      )
    )
    #expect(presentation.stepRailTargetItem?.id == "ready")

    let backlogOnly = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [backlog],
        decisionItems: [],
        scopeSessionID: nil
      )
    )
    #expect(backlogOnly.stepRailTargetItem == nil)
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

  @Test("Lane strip sizing keeps collapsed rails compact")
  func laneStripSizingKeepsCollapsedRailsCompact() {
    let sizing = TaskBoardLaneStripSizing(
      minColumnWidth: 288,
      spacing: 16,
      collapsedColumnWidth: 72
    )
    let widths = sizing.columnWidths(
      for: 760,
      preferredWidths: [288, sizing.collapsedColumnWidth, 288],
      canExpand: [true, false, true]
    )

    #expect(widths == [328, 72, 328])
    #expect(
      sizing.columnWidths(
        for: 620,
        preferredWidths: [288, sizing.collapsedColumnWidth, 288],
        canExpand: [true, false, true]
      ) == [288, 72, 288]
    )
    #expect(
      sizing.resolvedWidth(
        for: 620,
        preferredWidths: [288, sizing.collapsedColumnWidth, 288]
      ) == 680
    )
  }

  @Test("Inline code formatter strips matched backticks and styles code spans")
  func inlineCodeFormatterStylesMatchedBackticks() {
    let raw = "feat(matches): add `matches` to shared `inbound.Rule` struct"
    let attributed = TaskBoardInlineCodeFormatter.attributedText(
      for: raw,
      codeFont: .body.monospaced()
    )

    #expect(
      TaskBoardInlineCodeFormatter.displayText(for: raw)
        == "feat(matches): add matches to shared inbound.Rule struct"
    )

    let codeRuns = attributed.runs.compactMap { run -> String? in
      guard run.backgroundColor != nil else { return nil }
      return String(attributed[run.range].characters)
    }

    #expect(codeRuns == ["matches", "inbound.Rule"])
  }

  @Test("Inline code formatter keeps unmatched backticks as plain text")
  func inlineCodeFormatterPreservesUnmatchedBackticks() {
    let raw = "Investigate `open span"
    let attributed = TaskBoardInlineCodeFormatter.attributedText(
      for: raw,
      codeFont: .body.monospaced()
    )

    #expect(TaskBoardInlineCodeFormatter.displayText(for: raw) == raw)
    #expect(!attributed.runs.contains(where: { $0.backgroundColor != nil }))
  }

  @Test("Human Required lane applies explicit backend status for imported GitHub inbox items")
  func humanRequiredLaneAppliesImportedGitHubInboxStatus() {
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

    #expect(TaskBoardInboxLane.humanRequired.taskBoardDropStatus(for: inboxItem) == .humanRequired)
  }

  @Test("Umbrella lane has no drop status: there is no workflow status it corresponds to")
  func umbrellaLaneHasNoDropStatus() {
    let item = taskBoardItem(id: "board-only", status: .todo)

    #expect(TaskBoardInboxLane.umbrella.taskBoardDropStatus == nil)
    #expect(TaskBoardInboxLane.umbrella.taskBoardDropStatus(for: item) == nil)
  }

  @Test("Agentic Review lane applies explicit backend status for manual items")
  func agenticReviewLaneAppliesExplicitBackendStatusForManualItems() {
    let manualItem = taskBoardItem(
      id: "board-only",
      status: .todo,
      planning: TaskBoardPlanningState(summary: "Review the plan")
    )

    #expect(TaskBoardInboxLane.agenticReview.taskBoardDropStatus(for: manualItem) == .agenticReview)
  }

  @Test("Task board item resolves Kuma background symbol from the project owner")
  func taskBoardItemResolvesKumaBackgroundSymbolFromProjectOwner() {
    let item = taskBoardItem(
      id: "kuma-item",
      status: .todo,
      projectId: "kumahq/kuma"
    )

    #expect(item.taskBoardBackgroundProviderSymbol == .kuma)
  }

  @Test("Task board item resolves Kong background symbol from GitHub owner case-insensitively")
  func taskBoardItemResolvesKongBackgroundSymbolFromGitHubOwnerCaseInsensitively() {
    let item = taskBoardItem(
      id: "kong-item",
      status: .todo,
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "Kong/gateway-operator#123",
          url: "https://github.com/Kong/gateway-operator/issues/123"
        )
      ]
    )

    #expect(item.taskBoardBackgroundProviderSymbol == .kong)
  }

  @Test("Task board item falls back to no background symbol for other owners")
  func taskBoardItemFallsBackToNoBackgroundSymbolForOtherOwners() {
    let item = taskBoardItem(
      id: "other-item",
      status: .todo,
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/repo#42",
          url: "https://github.com/example/repo/issues/42"
        )
      ]
    )

    #expect(item.taskBoardBackgroundProviderSymbol == nil)
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

  @Test("Lane metrics expose a rounded top accent cap")
  func laneMetricsExposeRoundedTopAccentCap() {
    let metrics = TaskBoardLaneMetrics(fontScale: 1)

    #expect(metrics.laneAccentHeight == 8)
    #expect(metrics.laneAccentVisibleHeight == 4)
    #expect(metrics.laneAccentCornerRadius == metrics.laneAccentHeight)
    #expect(metrics.laneAccentInteriorCornerRadius == metrics.laneAccentHeight)
  }

  @Test("Lane metrics expose collapsed rail geometry")
  func laneMetricsExposeCollapsedRailGeometry() {
    let metrics = TaskBoardLaneMetrics(fontScale: 1)

    #expect(metrics.laneCollapsedWidth == 72)
    #expect(metrics.laneCollapsedWidth < metrics.laneWidth)
    #expect(metrics.laneCollapsedBadgeSize > 0)
    #expect(metrics.laneCollapsedTitleHeight > metrics.laneCollapsedWidth)
  }

  @Test("Lane metrics align header body gap with side inset")
  func laneMetricsAlignHeaderBodyGapWithSideInset() {
    let regular = TaskBoardLaneMetrics(fontScale: 1)
    let large = TaskBoardLaneMetrics(fontScale: 1.8)

    #expect(
      abs(
        regular.headerBottomPadding + regular.laneHeaderBodyTopPadding - regular.laneInnerPadding
      ) < 0.001
    )
    #expect(
      abs(
        large.headerBottomPadding + large.laneHeaderBodyTopPadding - large.laneInnerPadding
      ) < 0.001
    )
  }

  @Test("Overview metrics share scaled board spacing and padding")
  func overviewMetricsShareScaledBoardSpacingAndPadding() {
    let regular = TaskBoardOverviewMetrics(fontScale: 1)
    let large = TaskBoardOverviewMetrics(fontScale: 1.8)

    #expect(regular.operationsCardMinWidth == 300)
    #expect(large.operationsCardMinWidth > regular.operationsCardMinWidth)
    #expect(large.operationsCardMaxWidth > regular.operationsCardMaxWidth)
    #expect(large.columnSpacing > regular.columnSpacing)
    #expect(large.boardVerticalPadding > regular.boardVerticalPadding)
    #expect(large.summaryPillHorizontalPadding > regular.summaryPillHorizontalPadding)
    #expect(large.summaryPillVerticalPadding > regular.summaryPillVerticalPadding)
  }
}

extension TaskBoardOverviewBehaviorTests {
  func inboxItem(
    taskID: String,
    status: TaskStatus = .inProgress,
    title: String = "Linked task"
  ) -> TaskBoardInboxItem {
    let item = TaskBoardInboxItem(
      session: PreviewFixtures.summary,
      task: WorkItem(
        taskId: taskID,
        title: title,
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

  func taskBoardItem(
    id: String,
    status: TaskBoardStatus,
    priority: TaskBoardPriority = .medium,
    targetProjectTypes: [String] = [],
    projectId: String? = "project-1",
    kind: TaskBoardItemKind = .task,
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
      projectId: projectId,
      targetProjectTypes: targetProjectTypes,
      agentMode: .interactive,
      kind: kind,
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

  func decision(
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
