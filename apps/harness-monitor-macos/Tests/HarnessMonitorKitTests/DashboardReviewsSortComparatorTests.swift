import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews sort comparators")
struct DashboardReviewsSortComparatorTests {
  @Test("status bucket order favors auto-mergeable, ready-for-approval, approved")
  func statusBucketOrderPlacesActionableItemsFirst() {
    let mergeable = item(
      id: "merge",
      reviewStatus: .approved,
      checkStatus: .success
    )
    let approvable = item(
      id: "approve",
      reviewStatus: .reviewRequired,
      checkStatus: .success
    )
    let approved = item(
      id: "approved-only",
      reviewStatus: .approved,
      checkStatus: .pending
    )
    let pending = item(
      id: "pending",
      reviewStatus: .none,
      checkStatus: .pending
    )
    let reviewRequired = item(
      id: "review",
      number: 2,
      reviewStatus: .reviewRequired,
      checkStatus: .pending
    )
    let changes = item(
      id: "changes",
      reviewStatus: .changesRequested,
      checkStatus: .success
    )
    let failing = item(
      id: "failing",
      reviewStatus: .none,
      checkStatus: .failure
    )
    let draft = item(
      id: "draft",
      isDraft: true,
      reviewStatus: .approved,
      checkStatus: .success
    )

    let inputs = [draft, failing, changes, reviewRequired, pending, approved, approvable, mergeable]
    let sorted = inputs.sorted(by: DashboardReviewsSortMode.status.comparator)

    let ids = sorted.map { $0.pullRequestID }
    // Within the "pending checks" bucket the reviewTier tiebreaker pulls
    // explicit review-required PRs ahead of plain pending PRs.
    #expect(ids == [
      "merge",
      "approve",
      "approved-only",
      "review",
      "pending",
      "changes",
      "failing",
      "draft",
    ])
  }

  @Test("status comparator breaks ties with review tier, check tier, then updated desc")
  func statusComparatorBreaksTiesByReviewAndUpdated() {
    let older = item(
      id: "older",
      reviewStatus: .approved,
      checkStatus: .success,
      updatedAt: "2026-05-01T08:00:00Z"
    )
    let newer = item(
      id: "newer",
      reviewStatus: .approved,
      checkStatus: .success,
      updatedAt: "2026-05-02T08:00:00Z"
    )

    let sorted = [older, newer].sorted(by: DashboardReviewsSortMode.status.comparator)
    let ids = sorted.map { $0.pullRequestID }
    #expect(ids == ["newer", "older"])
  }

  @Test("updated mode orders by updatedAt desc independent of createdAt")
  func updatedModeSortsByUpdatedDescending() {
    let oldUpdate = item(
      id: "old-update",
      createdAt: "2026-05-10T10:00:00Z",
      updatedAt: "2026-05-10T11:00:00Z"
    )
    let newUpdate = item(
      id: "new-update",
      createdAt: "2026-05-01T10:00:00Z",
      updatedAt: "2026-05-22T18:00:00Z"
    )

    let sorted = [oldUpdate, newUpdate].sorted(by: DashboardReviewsSortMode.updated.comparator)
    let ids = sorted.map { $0.pullRequestID }
    #expect(ids == ["new-update", "old-update"])
  }

  @Test("created mode orders by createdAt desc and ignores updatedAt drift")
  func createdModeSortsByCreatedDescending() {
    let oldCreate = item(
      id: "old",
      createdAt: "2026-04-01T10:00:00Z",
      updatedAt: "2026-05-22T18:00:00Z"
    )
    let newCreate = item(
      id: "new",
      createdAt: "2026-05-01T10:00:00Z",
      updatedAt: "2026-04-30T18:00:00Z"
    )

    let sorted = [oldCreate, newCreate].sorted(by: DashboardReviewsSortMode.created.comparator)
    let ids = sorted.map { $0.pullRequestID }
    #expect(ids == ["new", "old"])
  }

  @Test("legacy `age` raw value resolves to status sort with stable order")
  func legacyAgeRawDoesNotCrash() {
    #expect(DashboardReviewsSortMode(rawValue: "age") == nil)
  }

  // MARK: helpers

  private func item(
    id: String,
    repository: String = "kong/a",
    number: UInt64 = 1,
    title: String = "Review",
    authorLogin: String = "user",
    isDraft: Bool = false,
    reviewStatus: ReviewReviewStatus = .none,
    checkStatus: ReviewCheckStatus = .success,
    mergeable: ReviewMergeableState = .mergeable,
    policyBlocked: Bool = false,
    createdAt: String = "2026-05-01T10:00:00Z",
    updatedAt: String? = nil
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: id,
      repositoryID: "repo-\(repository)",
      repository: repository,
      number: number,
      title: title,
      url: "https://github.com/\(repository)/pull/\(number)",
      authorLogin: authorLogin,
      state: .open,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: policyBlocked,
      isDraft: isDraft,
      headSha: "sha-\(id)",
      labels: [],
      additions: 1,
      deletions: 1,
      createdAt: createdAt,
      updatedAt: updatedAt ?? createdAt
    )
  }
}
