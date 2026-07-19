import Foundation
import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@MainActor
@Suite("Task board card presentation worker")
struct TaskBoardCardPresentationWorkerTests {
  // MARK: - Inline code fragment parsing

  @Test("Fragment scan returns a single plain fragment when there are no backticks")
  func fragmentScanReturnsPlainFragmentWithoutBackticks() {
    let fragments = TaskBoardInlineCodeFormatter.fragments(in: "plain text, no code spans")

    #expect(fragments == [TaskBoardInlineCodeFragment(text: "plain text, no code spans", isCode: false)])
  }

  @Test("Fragment scan leaves an unmatched backtick as plain text")
  func fragmentScanLeavesUnmatchedBacktickAsPlainText() {
    let fragments = TaskBoardInlineCodeFormatter.fragments(in: "Investigate `open span")

    #expect(fragments == [TaskBoardInlineCodeFragment(text: "Investigate `open span", isCode: false)])
  }

  @Test("Fragment scan splits adjacent code spans without merging them")
  func fragmentScanSplitsAdjacentCodeSpans() {
    let fragments = TaskBoardInlineCodeFormatter.fragments(in: "`alpha``beta`")

    #expect(
      fragments == [
        TaskBoardInlineCodeFragment(text: "alpha", isCode: true),
        TaskBoardInlineCodeFragment(text: "beta", isCode: true),
      ]
    )
  }

  @Test("Fragment scan handles code spans separated by plain text")
  func fragmentScanHandlesCodeSpansSeparatedByPlainText() {
    let fragments = TaskBoardInlineCodeFormatter.fragments(in: "fix `alpha` and `beta` paths")

    #expect(
      fragments == [
        TaskBoardInlineCodeFragment(text: "fix ", isCode: false),
        TaskBoardInlineCodeFragment(text: "alpha", isCode: true),
        TaskBoardInlineCodeFragment(text: " and ", isCode: false),
        TaskBoardInlineCodeFragment(text: "beta", isCode: true),
        TaskBoardInlineCodeFragment(text: " paths", isCode: false),
      ]
    )
  }

  // MARK: - updatedAt date parsing

  @Test("Date parsing accepts fractional ISO8601 timestamps")
  func dateParsingAcceptsFractionalISO8601() {
    let date = TaskBoardCardDateParsing.parse("2026-05-14T10:01:02.500Z")

    #expect(date != nil)
  }

  @Test("Date parsing accepts plain ISO8601 timestamps")
  func dateParsingAcceptsPlainISO8601() {
    let date = TaskBoardCardDateParsing.parse("2026-05-14T10:01:02Z")

    #expect(date != nil)
  }

  @Test("Date parsing accepts legacy space-separated UTC timestamps")
  func dateParsingAcceptsSpaceSeparatedTimestamps() {
    let date = TaskBoardCardDateParsing.parse("2026-05-14 10:01:02")

    #expect(date != nil)
  }

  @Test("Date parsing returns nil for input matching none of the accepted formats")
  func dateParsingReturnsNilForInvalidInput() {
    #expect(TaskBoardCardDateParsing.parse("not-a-timestamp") == nil)
    #expect(TaskBoardCardDateParsing.parse("") == nil)
  }

  // MARK: - GitHub glyph resolution table

  @Test("Managed pull requests resolve the pull-request glyph")
  func managedPullRequestResolvesPullRequestGlyph() {
    let item = glyphItem(workflow: TaskBoardWorkflowState(prNumber: 7))

    #expect(TaskBoardGitHubCardGlyph.resolve(for: item)?.systemImage == "arrow.triangle.pull")
  }

  @Test("Unmanaged pull-request URL references resolve the review glyph")
  func pullRequestURLReferenceResolvesReviewGlyph() {
    let item = glyphItem(
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/project#7",
          url: "https://github.com/example/project/pull/7"
        )
      ]
    )

    #expect(TaskBoardGitHubCardGlyph.resolve(for: item)?.systemImage == "text.badge.checkmark")
  }

  @Test("Issue references resolve the issue glyph")
  func issueReferenceResolvesIssueGlyph() {
    let item = glyphItem(
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/project#9",
          url: "https://github.com/example/project/issues/9"
        )
      ]
    )

    #expect(TaskBoardGitHubCardGlyph.resolve(for: item)?.systemImage == "smallcircle.filled.circle")
  }

  @Test("A bare GitHub surface without pull or issue paths resolves the fallback glyph")
  func bareGitHubSurfaceResolvesFallbackGlyph() {
    let item = glyphItem(
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/project",
          url: "https://github.com/example/project"
        )
      ]
    )

    #expect(TaskBoardGitHubCardGlyph.resolve(for: item)?.systemImage == "number.circle")
  }

  @Test("Items with no GitHub surface resolve no glyph")
  func noGitHubSurfaceResolvesNoGlyph() {
    let item = glyphItem()

    #expect(TaskBoardGitHubCardGlyph.resolve(for: item) == nil)
  }

  // MARK: - Worker: repository label disambiguation

  @Test("Worker precomputes both repository label variants, disambiguating duplicate names")
  func workerPrecomputesRepositoryLabelVariants() async throws {
    let worker = TaskBoardOverviewPresentationWorker()
    let ambiguous = glyphItem(id: "ambiguous-item", projectId: "alpha/console")
    let duplicateOwner = glyphItem(id: "duplicate-item", projectId: "beta/console")
    let unique = glyphItem(id: "unique-item", projectId: "gamma/widget")

    let presentation = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [ambiguous, duplicateOwner, unique],
        decisionItems: [],
        scopeSessionID: nil
      )
    )

    let ambiguousPresentation = try #require(presentation.apiCardPresentation(id: "ambiguous-item"))
    let uniquePresentation = try #require(presentation.apiCardPresentation(id: "unique-item"))

    #expect(ambiguousPresentation.repositoryLabelDefault == "alpha/console")
    #expect(ambiguousPresentation.repositoryLabelFullName == "alpha/console")
    #expect(uniquePresentation.repositoryLabelDefault == "widget")
    #expect(uniquePresentation.repositoryLabelFullName == "gamma/widget")
  }

  @Test("Worker precomputes inbox card title fragments and updatedAt off the raw item")
  func workerPrecomputesInboxCardPresentation() async {
    let worker = TaskBoardOverviewPresentationWorker()
    let inbox = inboxItem(taskID: "task-1", title: "Improve `cache` behavior")
    let cardID = TaskBoardCardID.inbox(sessionID: inbox.session.sessionId, taskID: "task-1")

    let presentation = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(items: [inbox]),
        taskBoardItems: [],
        decisionItems: [],
        scopeSessionID: nil
      )
    )

    let cardPresentation = presentation.inboxCardPresentation(id: cardID)

    #expect(cardPresentation?.titleDisplayText == "Improve cache behavior")
    #expect(cardPresentation?.titleFragments.contains(where: \.isCode) == true)
    #expect(cardPresentation?.updatedAt != nil)
  }

  // MARK: - Decision primary-action selection

  @Test("Primary action selection prefers a prominent action over dismiss and snooze")
  func primaryActionSelectionPrefersProminentAction() {
    let actions = [
      SuggestedAction(id: "dismiss", title: "Dismiss", kind: .dismiss, payloadJSON: "{}"),
      SuggestedAction(id: "assign", title: "Assign to agent", kind: .assignTask, payloadJSON: "{}"),
    ]

    let resolved = TaskBoardDecisionPrimaryActionCache.resolve(
      decisionID: "decision-1",
      suggestedActionsJSON: encoded(actions)
    )

    #expect(resolved?.id == "assign")
  }

  @Test("Primary action selection falls back to the first action when none are prominent")
  func primaryActionSelectionFallsBackWhenNoneProminent() {
    let actions = [
      SuggestedAction(id: "snooze", title: "Snooze", kind: .snooze, payloadJSON: "{}"),
      SuggestedAction(id: "dismiss", title: "Dismiss", kind: .dismiss, payloadJSON: "{}"),
    ]

    let resolved = TaskBoardDecisionPrimaryActionCache.resolve(
      decisionID: "decision-2",
      suggestedActionsJSON: encoded(actions)
    )

    #expect(resolved?.id == "snooze")
  }

  @Test("Primary action selection returns nil for empty or invalid JSON")
  func primaryActionSelectionReturnsNilForEmptyOrInvalidJSON() {
    #expect(
      TaskBoardDecisionPrimaryActionCache.resolve(
        decisionID: "decision-3",
        suggestedActionsJSON: encoded([SuggestedAction]())
      ) == nil
    )
    #expect(
      TaskBoardDecisionPrimaryActionCache.resolve(
        decisionID: "decision-4",
        suggestedActionsJSON: "not json"
      ) == nil
    )
  }

  @Test("Primary action cache re-resolves once content changes for the same decision id")
  func primaryActionCacheReResolvesOnContentChange() {
    let firstActions = [
      SuggestedAction(id: "assign", title: "Assign to agent", kind: .assignTask, payloadJSON: "{}")
    ]
    let secondActions = [
      SuggestedAction(id: "nudge", title: "Nudge agent", kind: .nudge, payloadJSON: "{}")
    ]

    let first = TaskBoardDecisionPrimaryActionCache.resolve(
      decisionID: "decision-5",
      suggestedActionsJSON: encoded(firstActions)
    )
    let cached = TaskBoardDecisionPrimaryActionCache.resolve(
      decisionID: "decision-5",
      suggestedActionsJSON: encoded(firstActions)
    )
    let updated = TaskBoardDecisionPrimaryActionCache.resolve(
      decisionID: "decision-5",
      suggestedActionsJSON: encoded(secondActions)
    )

    #expect(first?.id == "assign")
    #expect(cached?.id == "assign")
    #expect(updated?.id == "nudge")
  }

  // MARK: - Fixtures

  private func glyphItem(
    id: String = "glyph-item",
    projectId: String? = "example/project",
    externalRefs: [TaskBoardExternalRef] = [],
    workflow: TaskBoardWorkflowState? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item",
      body: "Body",
      status: .todo,
      priority: .medium,
      tags: [],
      projectId: projectId,
      agentMode: .interactive,
      externalRefs: externalRefs,
      planning: TaskBoardPlanningState(),
      workflow: workflow,
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-13T10:00:00Z",
      updatedAt: "2026-07-13T10:01:00Z",
      deletedAt: nil
    )
  }

  private func inboxItem(taskID: String, title: String) -> TaskBoardInboxItem {
    let item = TaskBoardInboxItem(
      session: PreviewFixtures.summary,
      task: WorkItem(
        taskId: taskID,
        title: title,
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

  private func encoded(_ actions: [SuggestedAction]) -> String {
    let data = try? JSONEncoder().encode(actions)
    guard let data, let json = String(data: data, encoding: .utf8) else {
      preconditionFailure("expected suggested actions to encode")
    }
    return json
  }
}
