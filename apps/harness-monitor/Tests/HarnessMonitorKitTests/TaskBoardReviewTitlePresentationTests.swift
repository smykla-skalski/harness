import SwiftUI
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task board review title presentation")
struct TaskBoardReviewTitlePresentationTests {
  @Test("Active imported pull request gets the review prefix in any local lane")
  func activeImportedPullRequestGetsReviewPrefix() {
    let item = taskBoardItem(
      title: "Improve `cache` behavior",
      status: .inProgress,
      importedFromProvider: .gitHub,
      referenceURL: "https://github.com/example/project/pull/42",
      syncedStatus: .todo
    )

    let presentation = TaskBoardCardTitlePresentation(item: item)

    #expect(item.requiresViewerGitHubReview)
    #expect(presentation.leadingText == "Review: ")
    #expect(presentation.title == "Improve `cache` behavior")
  }

  @Test("Legacy imported pull request without sync status remains active")
  func legacyImportedPullRequestRemainsActive() {
    let item = taskBoardItem(
      importedFromProvider: .gitHub,
      referenceURL: "https://github.com/example/project/pull/42"
    )

    #expect(item.requiresViewerGitHubReview)
  }

  @Test("Review references require secure GitHub pull request URLs")
  func reviewReferencesRequireSecureGitHubURLs() {
    let insecure = taskBoardItem(
      importedFromProvider: .gitHub,
      referenceURL: "http://github.com/example/project/pull/42"
    )
    let otherHost = taskBoardItem(
      importedFromProvider: .gitHub,
      referenceURL: "https://code.example.com/example/project/pull/42"
    )
    let padded = taskBoardItem(
      importedFromProvider: .gitHub,
      referenceURL: "  https://github.com/example/project/pull/42\n"
    )

    #expect(!insecure.requiresViewerGitHubReview)
    #expect(!otherHost.requiresViewerGitHubReview)
    #expect(padded.requiresViewerGitHubReview)
  }

  @Test("Completed, manual, and issue references do not get the review prefix")
  func nonReviewTasksDoNotGetReviewPrefix() {
    let completed = taskBoardItem(
      status: .inProgress,
      importedFromProvider: .gitHub,
      referenceURL: "https://github.com/example/project/pull/42",
      syncedStatus: .done
    )
    let manual = taskBoardItem(
      referenceURL: "https://github.com/example/project/pull/42",
      syncedStatus: .todo
    )
    let issue = taskBoardItem(
      importedFromProvider: .gitHub,
      referenceURL: "https://github.com/example/project/issues/42",
      syncedStatus: .todo
    )

    #expect(!completed.requiresViewerGitHubReview)
    #expect(!manual.requiresViewerGitHubReview)
    #expect(!issue.requiresViewerGitHubReview)
    #expect(TaskBoardCardTitlePresentation(item: completed).leadingText == nil)
    #expect(TaskBoardCardTitlePresentation(item: manual).leadingText == nil)
    #expect(TaskBoardCardTitlePresentation(item: issue).leadingText == nil)
  }

  @Test("Existing review prefix is split without duplication")
  func existingReviewPrefixIsSplitWithoutDuplication() {
    let item = taskBoardItem(
      title: "review:   Improve caching",
      importedFromProvider: .gitHub,
      referenceURL: "https://github.com/example/project/pull/42",
      syncedStatus: .todo
    )

    let presentation = TaskBoardCardTitlePresentation(item: item)

    #expect(presentation.leadingText == "Review: ")
    #expect(presentation.title == "Improve caching")
  }

  @Test("Prefix and inline code share one attributed title and accessibility string")
  func prefixAndInlineCodeShareOneAttributedTitle() {
    let title = "Improve `cache` behavior"
    let leadingText = "Review: "
    let attributed = TaskBoardInlineCodeFormatter.attributedText(
      for: title,
      codeFont: .body.monospaced(),
      leadingText: leadingText
    )

    #expect(
      TaskBoardInlineCodeFormatter.displayText(for: title, leadingText: leadingText)
        == "Review: Improve cache behavior"
    )
    let styledRuns = attributed.runs.compactMap { run -> String? in
      guard run.foregroundColor != nil else { return nil }
      return String(attributed[run.range].characters)
    }
    #expect(styledRuns.contains("Review: "))
    #expect(styledRuns.contains("cache"))
  }

  @Test("Preview updates preserve review provenance and sync status")
  func previewUpdatesPreserveReviewIdentity() {
    let item = taskBoardItem(
      importedFromProvider: .gitHub,
      referenceURL: "https://github.com/example/project/pull/42",
      syncedStatus: .todo
    )

    let updated = item.applyingPreviewUpdate(TaskBoardUpdateItemRequest(status: .inProgress))

    #expect(updated.importedFromProvider == .gitHub)
    #expect(updated.externalRefs.first?.syncState?.status == .todo)
    #expect(updated.requiresViewerGitHubReview)
  }

  private func taskBoardItem(
    title: String = "Improve caching",
    status: TaskBoardStatus = .todo,
    importedFromProvider: TaskBoardExternalRefProvider? = nil,
    referenceURL: String,
    syncedStatus: TaskBoardStatus? = nil
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "review-item",
      title: title,
      body: "Body",
      status: status,
      priority: .medium,
      tags: [],
      projectId: "example/project",
      agentMode: .interactive,
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/project#42",
          url: referenceURL,
          syncState: syncedStatus.map { TaskBoardExternalRefSyncState(status: $0) }
        )
      ],
      importedFromProvider: importedFromProvider,
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
}
