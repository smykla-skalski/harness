import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews approve/merge prominence policy")
struct DashboardReviewsActionProminenceTests {
  @Test("Approve prominence is primary for clean selections")
  func approveProminenceIsPrimaryForCleanSelections() {
    let clean = makeItem(state: .open, reviewStatus: .reviewRequired, checkStatus: .success)

    #expect(dashboardReviewApproveProminence(for: [clean]) == .primary)
  }

  @Test("Approve prominence stays primary when selection needs attention")
  func approveProminenceStaysPrimaryWhenSelectionNeedsAttention() {
    let failing = makeItem(state: .open, reviewStatus: .approved, checkStatus: .failure)

    #expect(failing.requiresAttention)
    #expect(dashboardReviewApproveProminence(for: [failing]) == .primary)
  }

  @Test("Approve prominence stays primary for admin-bypass required failures")
  func approveProminenceStaysPrimaryForAdminBypassRequiredFailures() {
    let adminBypass = makeItem(
      state: .open,
      reviewStatus: .approved,
      checkStatus: .failure,
      requiredFailedCheckNames: ["ci / test"],
      viewerCanMergeAsAdmin: true
    )

    #expect(adminBypass.requiresAttention)
    #expect(adminBypass.requiresAdminMergeForRequiredFailures)
    #expect(dashboardReviewApproveProminence(for: [adminBypass]) == .primary)
  }

  @Test("Approve prominence stays primary in mixed selections")
  func approveProminenceStaysPrimaryInMixedSelections() {
    let clean = makeItem(state: .open, reviewStatus: .reviewRequired, checkStatus: .success)
    let failing = makeItem(state: .open, reviewStatus: .approved, checkStatus: .failure)

    #expect(dashboardReviewApproveProminence(for: [clean, failing]) == .primary)
  }

  @Test("Merge prominence still varies independently of approve")
  func mergeProminenceStillVariesIndependentlyOfApprove() {
    let clean = makeItem(state: .open, reviewStatus: .approved, checkStatus: .success)
    let failing = makeItem(
      state: .open,
      reviewStatus: .approved,
      checkStatus: .failure,
      requiredFailedCheckNames: [],
      viewerCanMergeAsAdmin: true
    )
    let adminBypass = makeItem(
      state: .open,
      reviewStatus: .approved,
      checkStatus: .failure,
      requiredFailedCheckNames: ["ci / test"],
      viewerCanMergeAsAdmin: true
    )

    #expect(dashboardReviewMergeProminence(for: [clean]) == .success)
    #expect(dashboardReviewMergeProminence(for: [failing]) == .warning)
    #expect(dashboardReviewMergeProminence(for: [adminBypass]) == .destructive)
  }

  private func makeItem(
    state: ReviewPullRequestState = .open,
    mergeable: ReviewMergeableState = .mergeable,
    reviewStatus: ReviewReviewStatus = .reviewRequired,
    checkStatus: ReviewCheckStatus = .success,
    policyBlocked: Bool = false,
    isDraft: Bool = false,
    checks: [ReviewCheck] = [],
    viewerCanUpdate: Bool = true,
    requiredFailedCheckNames: [String] = [],
    viewerCanMergeAsAdmin: Bool = false
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: "pr-1",
      repositoryID: "repo-1",
      repository: "org-a/example",
      number: 42,
      title: "Bump dependency",
      url: "https://github.com/org-a/example/pull/42",
      authorLogin: "renovate[bot]",
      state: state,
      mergeable: mergeable,
      reviewStatus: reviewStatus,
      checkStatus: checkStatus,
      policyBlocked: policyBlocked,
      isDraft: isDraft,
      headSha: "abc123",
      labels: [],
      checks: checks,
      reviews: [],
      additions: 10,
      deletions: 4,
      createdAt: "2026-05-20T10:00:00Z",
      updatedAt: "2026-05-20T11:00:00Z",
      requiredFailedCheckNames: requiredFailedCheckNames,
      viewerCanUpdate: viewerCanUpdate,
      viewerCanMergeAsAdmin: viewerCanMergeAsAdmin
    )
  }
}
