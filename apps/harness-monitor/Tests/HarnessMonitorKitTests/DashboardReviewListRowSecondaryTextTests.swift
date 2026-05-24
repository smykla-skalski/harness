import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review list row secondary text")
@MainActor
struct DashboardReviewListRowSecondaryTextTests {
  @Test("repository-scoped row shows `repository · #N` only")
  func repositoryScopedRowShowsRepositoryAndNumberOnly() {
    let row = makeRow(showsRepository: true)
    #expect(row.secondaryText == "octocat/example · #42")
  }

  @Test("repository-hidden row collapses the secondary line")
  func repositoryHiddenRowCollapsesTheSecondaryLine() {
    let row = makeRow(showsRepository: false)
    // When the list is grouped by repository, `#N` rides inline on the status
    // line so the row never burns a caption line on the PR number alone.
    #expect(row.secondaryText == nil)
  }

  @Test("status label drops the redundant review-status joiner")
  func secondaryTextDoesNotJoinStatusOrReviewLabels() {
    let row = makeRow(
      showsRepository: true,
      reviewStatus: .approved,
      checkStatus: .success
    )
    let secondary = row.secondaryText ?? ""
    // Items 21 + 35: the second line is identity-only now.
    #expect(!secondary.contains("Ready"))
    #expect(!secondary.contains("Approved"))
    #expect(!secondary.contains("Review required"))
  }

  @Test("reviewer summary derives unique reviewer count and approvals")
  func reviewerSummaryDerivesUniqueReviewerCountAndApprovals() {
    let reviews = [
      PullRequestReview(author: "alice", state: .commented),
      PullRequestReview(author: "alice", state: .approved),
      PullRequestReview(author: "bob", state: .changesRequested),
      PullRequestReview(author: "carol", state: .approved),
    ]

    let summary = DashboardReviewerSummary(reviews: reviews)

    #expect(summary.reviewerCount == 3)
    #expect(summary.approvedCount == 2)
  }

  @Test("empty reviews collapse the reviewer summary entirely")
  func emptyReviewsCollapseTheReviewerSummary() {
    let summary = DashboardReviewerSummary(reviews: [])
    #expect(summary.reviewerCount == 0)
  }

  private func makeRow(
    showsRepository: Bool,
    reviewStatus: ReviewReviewStatus = .reviewRequired,
    checkStatus: ReviewCheckStatus = .pending
  ) -> DashboardReviewListRow {
    DashboardReviewListRow(
      item: ReviewItem(
        pullRequestID: "pr-1",
        repositoryID: "repo-1",
        repository: "octocat/example",
        number: 42,
        title: "Bump dependency",
        url: "https://github.com/octocat/example/pull/42",
        authorLogin: "octocat",
        state: .open,
        mergeable: .mergeable,
        reviewStatus: reviewStatus,
        checkStatus: checkStatus,
        policyBlocked: false,
        isDraft: false,
        headSha: "abc123",
        additions: 12,
        deletions: 3,
        createdAt: "2026-05-22T10:00:00Z",
        updatedAt: "2026-05-22T11:00:00Z"
      ),
      showsRepository: showsRepository,
      isRefreshing: false,
      actionTitle: nil,
      updatedLabel: "3h ago"
    )
  }
}
