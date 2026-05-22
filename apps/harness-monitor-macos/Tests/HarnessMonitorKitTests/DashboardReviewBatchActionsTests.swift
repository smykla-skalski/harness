import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard dependency batch actions")
struct DashboardDependencyBatchActionsTests {
  @Test("batch eligibility summarizes actionable and skipped merge targets")
  func batchEligibilitySummarizesActionableAndSkippedMergeTargets() {
    let ready = dependencyItem(
      id: "ready",
      number: 1,
      reviewStatus: .approved,
      checkStatus: .success
    )
    let readOnly = dependencyItem(
      id: "readonly",
      number: 2,
      reviewStatus: .approved,
      checkStatus: .success,
      viewerCanUpdate: false
    )
    let conflicting = dependencyItem(
      id: "conflicting",
      number: 3,
      reviewStatus: .approved,
      mergeable: .conflicting,
      checkStatus: .success
    )

    let preview = DashboardDependencyBatchEligibility.preview(
      kind: .merge,
      items: [ready, readOnly, conflicting]
    )

    #expect(preview.actionableCount == 1)
    #expect(preview.skippedCount == 2)
    #expect(
      preview.skippedReasons.map(\.reason)
        .contains("Merge conflicts must be resolved before merging")
    )
    #expect(
      preview.skippedReasons.map(\.reason)
        .contains("Current GitHub token cannot update selected pull request(s)")
    )
  }

  @Test("local action preview includes skipped merge targets")
  func localActionPreviewIncludesSkippedMergeTargets() {
    let ready = dependencyItem(
      id: "ready",
      number: 1,
      reviewStatus: .approved,
      checkStatus: .success
    )
    let blocked = dependencyItem(
      id: "blocked",
      number: 2,
      reviewStatus: .changesRequested,
      mergeable: .conflicting,
      checkStatus: .success
    )

    let preview = localDependencyActionPreview(
      .merge,
      items: [ready, blocked]
    )

    #expect(preview.actionableCount == 1)
    #expect(preview.skippedCount == 1)
    #expect(
      preview.targets.contains {
        $0.pullRequestID == "blocked"
          && $0.reason == "Merge conflicts must be resolved before merging"
      }
    )
  }

  private func dependencyItem(
    id: String,
    number: UInt64,
    reviewStatus: DependencyUpdateReviewStatus,
    mergeable: DependencyUpdateMergeableState = .mergeable,
    checkStatus: DependencyUpdateCheckStatus,
    viewerCanUpdate: Bool = true
  ) -> DependencyUpdateItem {
    DependencyUpdateItem(
      pullRequestID: id,
      repositoryID: "repo-1",
      repository: "org-a/example",
      number: number,
      title: "Bump dependency",
      url: "https://github.com/org-a/example/pull/\(number)",
      authorLogin: "renovate[bot]",
      state: .open,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: false,
      isDraft: false,
      headSha: "abc123",
      additions: 10,
      deletions: 4,
      createdAt: "2026-05-20T10:00:00Z",
      updatedAt: "2026-05-20T11:00:00Z",
      viewerCanUpdate: viewerCanUpdate
    )
  }
}
