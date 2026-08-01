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
        scopeSessionID: "sess-current",
        taskBoardProjects: []
      )
    )

    #expect(presentation.taskBoardItems.map(\.id) == ["session-item"])
    #expect(presentation.apiItems(in: .todo).map(\.id) == ["session-item"])
  }

  @Test("Immediate drop projection settles lanes without rebuilding card presentation")
  func immediateDropProjectionSettlesLanesWithoutCardRebuild() async throws {
    let worker = TaskBoardOverviewPresentationWorker()
    let firstTodo = taskBoardItem(id: "todo-first", status: .todo)
    let movedTodo = taskBoardItem(
      id: "todo-moved",
      status: .todo,
      sourceProjectId: "registered-project"
    )
    let planning = taskBoardItem(id: "planning-anchor", status: .planning)
    let project = TaskBoardProjectSummary(
      projectId: "registered-project",
      source: .manual,
      slug: "project-1",
      color: .amber,
      shape: .hexagon,
      itemCount: 1,
      readyCount: 1
    )
    let presentation = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [firstTodo, movedTodo, planning],
        decisionItems: [],
        scopeSessionID: nil,
        taskBoardProjects: [project]
      )
    )
    let movedToPlanning = taskBoardItem(
      id: movedTodo.id,
      status: .planning,
      sourceProjectId: "registered-project"
    )
    let cachedPresentation = try #require(
      presentation.apiCardPresentations(in: .todo)[movedTodo.id]
    )
    #expect(
      cachedPresentation.projectMark
        == TaskBoardProjectMarkStyle(color: .amber, shape: .hexagon)
    )

    let projected = presentation.replacingTaskBoardItemsForImmediatePosition(
      [firstTodo, planning, movedToPlanning],
      scopeSessionID: nil
    )

    #expect(projected.apiItems(in: .todo).map(\.id) == [firstTodo.id])
    #expect(
      projected.apiItems(in: .planning).map(\.id)
        == [planning.id, movedTodo.id]
    )
    #expect(
      projected.apiCardPresentations(in: .planning)[movedTodo.id]
        == cachedPresentation
    )
    #expect(
      projected.apiCardPresentations(in: .planning)[movedTodo.id]?.projectMark
        == cachedPresentation.projectMark
    )
    #expect(
      projected.orderedCardIDs
        == [.api(firstTodo.id), .api(planning.id), .api(movedTodo.id)]
    )
  }

  @Test("Immediate drop projection preserves active facet and search membership")
  func immediateDropProjectionPreservesFacetAndSearchMembership() async {
    var filters = TaskBoardFilterState()
    filters.toggleTag("visible")
    let moved = taskBoardItem(
      id: "moved",
      status: .todo,
      title: "Needle moving",
      tags: ["visible"]
    )
    let hiddenByFacet = taskBoardItem(
      id: "hidden-by-facet",
      status: .todo,
      title: "Needle hidden by facet",
      tags: ["hidden"]
    )
    let hiddenBySearch = taskBoardItem(
      id: "hidden-by-search",
      status: .todo,
      title: "Different title",
      tags: ["visible"]
    )
    let presentation = await TaskBoardOverviewPresentationWorker().compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [moved, hiddenByFacet, hiddenBySearch],
        decisionItems: [],
        scopeSessionID: nil,
        taskBoardProjects: [],
        filters: filters,
        searchText: "needle"
      )
    )
    let movedToPlanning = taskBoardItem(
      id: moved.id,
      status: .planning,
      title: moved.title,
      tags: moved.tags
    )

    let projected = presentation.replacingTaskBoardItemsForImmediatePosition(
      [hiddenByFacet, hiddenBySearch, movedToPlanning],
      scopeSessionID: nil
    )

    #expect(projected.taskBoardItems.map(\.id) == [moved.id])
    #expect(projected.apiItems(in: .todo).isEmpty)
    #expect(projected.apiItems(in: .planning).map(\.id) == [moved.id])
    #expect(projected.taskBoardItemsByID[hiddenByFacet.id] == nil)
    #expect(projected.taskBoardItemsByID[hiddenBySearch.id] == nil)
    #expect(projected.orderedCardIDs == [.api(moved.id)])
  }

  @Test("Immediate drop projection preserves same-lane order and session scope")
  func immediateDropProjectionPreservesSameLaneOrderAndScope() async {
    let worker = TaskBoardOverviewPresentationWorker()
    let first = taskBoardItem(id: "first", status: .todo, sessionId: "selected")
    let moved = taskBoardItem(id: "moved", status: .todo, sessionId: "selected")
    let otherSession = taskBoardItem(id: "other", status: .todo, sessionId: "other")
    let presentation = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [first, moved, otherSession],
        decisionItems: [],
        scopeSessionID: "selected",
        taskBoardProjects: []
      )
    )

    let projected = presentation.replacingTaskBoardItemsForImmediatePosition(
      [moved, otherSession, first],
      scopeSessionID: "selected"
    )

    #expect(projected.apiItems(in: .todo).map(\.id) == [moved.id, first.id])
    #expect(projected.taskBoardItemsByID[otherSession.id] == nil)
    #expect(projected.orderedCardIDs == [.api(moved.id), .api(first.id)])
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
        scopeSessionID: nil,
        taskBoardProjects: []
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
        scopeSessionID: nil,
        taskBoardProjects: []
      )
    )

    #expect(presentation.aggregateDoneCount == 1)
    #expect(presentation.aggregateOpenCount == 0)
  }

  @Test("Step Mode targets the daemon's first Todo item and never another lane")
  func stepModeTargetIsTopTodoItem() async {
    let worker = TaskBoardOverviewPresentationWorker()
    let inbox = taskBoardItem(id: "inbox-item", status: .inbox)
    let todo = taskBoardItem(id: "ready-low", status: .todo, priority: .low)
    let laterHigherPriority = taskBoardItem(
      id: "later-critical", status: .todo, priority: .critical)

    let presentation = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [inbox, todo, laterHigherPriority],
        decisionItems: [],
        scopeSessionID: nil,
        taskBoardProjects: []
      )
    )
    #expect(presentation.apiItems(in: .todo).map(\.id) == ["ready-low", "later-critical"])
    #expect(presentation.stepRailTargetItem?.id == "ready-low")

    let inboxOnly = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [inbox],
        decisionItems: [],
        scopeSessionID: nil,
        taskBoardProjects: []
      )
    )
    #expect(inboxOnly.stepRailTargetItem == nil)
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

}
