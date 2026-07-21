import Foundation
import HarnessMonitorKit
import SwiftUI
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board card presentation contracts")
struct TaskBoardCardPresentationContractTests {
  @Test("Repository leads the footer before card badges")
  func repositoryLeadsFooterBeforeCardBadges() throws {
    let source = try taskBoardSource("TaskBoardLaneSupport.swift")
    let repository = try #require(source.range(of: "Text(repository)"))
    let badges = try #require(source.range(of: "HarnessMonitorWrapLayout("))
    let repositoryBlock = source[repository.lowerBound..<badges.lowerBound]

    #expect(repository.lowerBound < badges.lowerBound)
    #expect(repositoryBlock.contains("HarnessMonitorTheme.tertiaryInk"))
    #expect(!repositoryBlock.contains("HarnessMonitorTheme.secondaryInk"))
    #expect(source.contains(".multilineTextAlignment(.leading)"))
  }

  @Test("Card status glyph is kind-aware so a closed umbrella still gets its lane's icon")
  func cardStatusGlyphIsKindAware() throws {
    let rows = try taskBoardSource("TaskBoardLaneViews.swift")
    #expect(rows.contains("TaskBoardInboxLane(taskBoardItem: item)"))
  }

  @Test("Review prefix stays in the card title text flow with reduced emphasis")
  func reviewPrefixStaysInCardTitleTextFlowWithReducedEmphasis() throws {
    let rows = try taskBoardSource("TaskBoardLaneViews.swift")
    let text = try taskBoardSource("TaskBoardInlineCodeText.swift")

    #expect(rows.contains("fallbackTitlePresentation.title"))
    #expect(rows.contains("titleLeadingText"))
    #expect(text.contains("attributedLeadingText.foregroundColor = leadingForeground"))
    #expect(text.contains("leadingForeground: Color = HarnessMonitorTheme.tertiaryInk"))
    #expect(!rows.contains("Text(\"Review: \""))
  }

  @Test("Card update labels share one board-owned minute clock")
  func cardUpdateLabelsShareBoardClock() throws {
    let overview = try taskBoardSource("TaskBoardOverviewView.swift")
    let rows = try taskBoardSource("TaskBoardLaneViews.swift")
    let support = try taskBoardSource("TaskBoardLaneSupport.swift")

    #expect(overview.contains("@State private var relativeTimeClock"))
    #expect(overview.contains(".environment(relativeTimeClock)"))
    #expect(overview.contains("await relativeTimeClock.run()"))
    #expect(rows.components(separatedBy: "updatedAt: updatedAtDate").count == 3)
    #expect(support.contains("@Environment(TaskBoardRelativeTimeClock.self)"))
    #expect(support.contains("Task.sleep(for: .seconds(60))"))
    #expect(support.contains("let referenceDate = relativeTimeClock.referenceDate"))
    #expect(support.contains("let accessibleAge ="))
    #expect(
      support.contains("formatRelativeUpdatedAt(updatedAt, reference: referenceDate)")
    )
    #expect(support.contains("label == \"just now\""))
    #expect(support.contains(".accessibilityLabel(\"Updated \\(accessibleAge)\")"))
    #expect(!support.contains(".accessibilityLabel(\"Updated \\(label)\")"))
    #expect(!rows.contains("TimelineView"))
    #expect(!rows.contains("Timer.publish"))
  }

  @Test("Card update labels stay smaller and dimmer than repository metadata")
  func cardUpdateLabelsStaySmallerAndDimmerThanRepositoryMetadata() throws {
    let support = try taskBoardSource("TaskBoardLaneSupport.swift")

    #expect(
      support.contains(
        "HarnessMonitorTextSize.scaledFont(.system(size: 8), by: fontScale)"
      )
    )
    #expect(
      support.contains("HarnessMonitorTheme.tertiaryInk.opacity(0.8)")
    )
  }

  @Test("Board resolves scaled task-title fonts once and passes them through lanes")
  func boardPassesScaledTaskTitleFontsThroughLanes() throws {
    let overviewSource = try taskBoardSource("TaskBoardOverviewView+Board.swift")
    let laneSource = try taskBoardSource("TaskBoardLaneUnifiedColumn.swift")
    let rowSource = try taskBoardSource("TaskBoardLaneViews.swift")
    let textSource = try taskBoardSource("TaskBoardInlineCodeText.swift")

    #expect(
      overviewSource.contains(
        "let titleTypography = TaskBoardCardTitleTypography(fontScale: fontScale)"
      )
    )
    #expect(overviewSource.contains("taskBoardLaneColumns(titleTypography: titleTypography)"))
    #expect(laneSource.components(separatedBy: "titleTypography: titleTypography").count == 3)
    #expect(laneSource.contains("let titleTypography: TaskBoardCardTitleTypography"))
    #expect(rowSource.contains("let titleTypography: TaskBoardCardTitleTypography"))
    #expect(!textSource.contains("@Environment(\\.fontScale)"))
    #expect(textSource.contains("codeFont: codeFont"))
    #expect(textSource.contains(".font(font)"))
  }

  @Test("Cards omit background glyphs while retaining the reusable modifier")
  func cardsOmitBackgroundGlyphsWhileRetainingModifier() throws {
    let laneSource = try taskBoardSource("TaskBoardLaneViews.swift")
    let decisionSource = try taskBoardSource("TaskBoardNeedsYouLaneViews.swift")
    let glyphSource = try taskBoardSource("TaskBoardCardBackgroundGlyph.swift")

    #expect(!laneSource.contains(".taskBoardCardBackgroundGlyph("))
    #expect(!decisionSource.contains(".taskBoardCardBackgroundGlyph("))
    #expect(glyphSource.contains("func taskBoardCardBackgroundGlyph("))
    #expect(glyphSource.contains(".rotationEffect(glyphRotation)"))
  }

  @Test("Card rows accept an explicit cardPresentation argument")
  func cardRowsAcceptExplicitCardPresentation() {
    // Compile-level proof: `var` (not `let`) so this stays passable via the memberwise init.
    let presentation = TaskBoardCardPresentation(
      titleFragments: [TaskBoardInlineCodeFragment(text: "Improve caching", isCode: false)],
      titleLeadingText: nil,
      titleDisplayText: "Improve caching",
      glyph: nil,
      updatedAt: nil,
      repositoryLabelDefault: nil,
      repositoryLabelFullName: nil
    )
    let typography = TaskBoardCardTitleTypography(fontScale: 1)
    let selectionModel = TaskBoardCardSelectionModel()
    let actions = TaskBoardOverviewActions(store: nil, scope: .dashboard)

    let apiRow = TaskBoardItemRow(
      item: contractTaskBoardItem(),
      titleTypography: typography,
      isHovered: false,
      isSelected: false,
      selectionModel: selectionModel,
      actions: actions,
      cardPresentation: presentation
    )
    let inboxRow = TaskBoardInboxItemRow(
      item: contractInboxItem(),
      titleTypography: typography,
      isHovered: false,
      isSelected: false,
      selectionModel: selectionModel,
      actions: actions,
      cardPresentation: presentation
    )

    #expect(apiRow.cardPresentation == presentation)
    #expect(inboxRow.cardPresentation == presentation)
  }

  @Test("Lane column wires precomputed presentations into both row constructors")
  func laneColumnWiresCardPresentationIntoRows() throws {
    let columnSource = try taskBoardSource("TaskBoardLaneUnifiedColumn.swift")
    let boardSource = try taskBoardSource("TaskBoardOverviewView+Board.swift")

    #expect(columnSource.contains("let apiCardPresentations: [String: TaskBoardCardPresentation]"))
    #expect(
      columnSource.contains(
        "let inboxCardPresentations: [TaskBoardCardID: TaskBoardCardPresentation]"
      )
    )
    #expect(columnSource.contains("cardPresentation: apiCardPresentations[item.id]"))
    #expect(columnSource.contains("cardPresentation: inboxCardPresentations[cardID]"))
    #expect(
      boardSource.contains(
        "apiCardPresentations: currentPresentation.apiCardPresentations(in: lane)"
      )
    )
    #expect(
      boardSource.contains(
        "inboxCardPresentations: currentPresentation.inboxCardPresentations(in: lane)"
      )
    )
  }

  @Test("Decision row accepts actions in place of the onOpenDecision closure")
  func decisionRowAcceptsActionsInsteadOfClosure() {
    let actions = TaskBoardOverviewActions(store: nil, scope: .dashboard)
    let decision = Decision(
      id: "contract-decision",
      severity: .warn,
      ruleID: "rule-contract",
      sessionID: nil,
      agentID: nil,
      taskID: nil,
      summary: "Contract summary",
      contextJSON: "{}",
      suggestedActionsJSON: "[]"
    )

    let row = TaskBoardDecisionRow(
      decision: decision,
      fontScale: 1,
      isHovered: false,
      actions: actions
    )

    #expect(row.actions == actions)
  }

  @Test("Lane column wires actions into the decision row instead of a closure")
  func laneColumnWiresDecisionRowActions() throws {
    let columnSource = try taskBoardSource("TaskBoardLaneUnifiedColumn.swift")
    let decisionSource = try taskBoardSource("TaskBoardNeedsYouLaneViews.swift")

    #expect(
      columnSource.contains("TaskBoardDecisionRow(") && columnSource.contains("actions: actions"))
    #expect(!columnSource.contains("onOpenDecision:"))
    #expect(!decisionSource.contains("onOpenDecision"))
    #expect(decisionSource.contains("actions.openDecision(decision)"))
  }

  private func contractTaskBoardItem() -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "contract-item",
      title: "Board item",
      body: "Body",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: "example/project",
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(),
      workflow: nil,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-13T10:00:00Z",
      updatedAt: "2026-07-13T10:01:00Z",
      deletedAt: nil
    )
  }

  private func contractInboxItem() -> TaskBoardInboxItem {
    let item = TaskBoardInboxItem(
      session: PreviewFixtures.summary,
      task: WorkItem(
        taskId: "contract-task",
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
    guard let item else {
      preconditionFailure("expected task board inbox item fixture")
    }
    return item
  }

  private func taskBoardSource(_ fileName: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot =
      testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let sourceURL =
      appRoot
      .appendingPathComponent("Sources/HarnessMonitorUIPreviewable/Views/TaskBoard")
      .appendingPathComponent(fileName)
    return try String(contentsOf: sourceURL, encoding: .utf8)
  }
}
