import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

/// Verifies the documented colour-role table on `HarnessMonitorTheme` and
/// the pill conventions on `DashboardReviewsVisualComponents.swift`.
/// These tests are deliberately string-keyed against the role table so a
/// future regression that swaps `.success` for `.accent` (or vice versa)
/// fails fast.
@Suite("Dashboard reviews pill role table")
struct DashboardReviewsPillRoleTests {
  @Test("pillCornerRadius lives on HarnessMonitorTheme")
  func pillCornerRadiusLivesOnTheme() {
    #expect(HarnessMonitorTheme.pillCornerRadius == 7)
  }

  @Test("DashboardReviewsVisualMetrics.pillCornerRadius forwards to theme")
  func dashboardMetricsForwardsToTheme() {
    #expect(
      DashboardReviewsVisualMetrics.pillCornerRadius == HarnessMonitorTheme.pillCornerRadius
    )
  }

  @MainActor
  @Test("healthy live source uses accent, not success")
  func healthyLiveSourceUsesAccent() {
    let snapshot = makeSnapshot(
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: false,
      connectionState: .online,
      health: DashboardReviewsSyncHealth(
        totalRepositoryCount: 1,
        syncingRepositoryCount: 0,
        failedRepositories: [],
        staleRepositories: []
      ),
      now: Date(timeIntervalSince1970: 1_779_440_700)
    )

    #expect(snapshot.overallHealth == .success)
    #expect(snapshot.sourceTint == HarnessMonitorTheme.accent)
    #expect(snapshot.sourceTint != HarnessMonitorTheme.success)
  }

  @MainActor
  @Test("caution source still uses caution tint")
  func cautionSourceUsesCaution() {
    let snapshot = makeSnapshot(
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: false,
      connectionState: .online,
      health: DashboardReviewsSyncHealth(
        totalRepositoryCount: 1,
        syncingRepositoryCount: 0,
        failedRepositories: [],
        staleRepositories: ["acme/api"]
      ),
      now: Date(timeIntervalSince1970: 1_779_440_700)
    )

    #expect(snapshot.overallHealth == .caution)
    #expect(snapshot.sourceTint == HarnessMonitorTheme.caution)
  }

  @MainActor
  @Test("offline source still uses danger tint")
  func offlineSourceUsesDanger() {
    let snapshot = makeSnapshot(
      fetchedAt: "2026-05-22T09:00:00Z",
      fromCache: true,
      connectionState: .offline("daemon stopped"),
      health: DashboardReviewsSyncHealth(
        totalRepositoryCount: 0,
        syncingRepositoryCount: 0,
        failedRepositories: [],
        staleRepositories: []
      ),
      now: Date(timeIntervalSince1970: 1_779_440_700)
    )

    #expect(snapshot.overallHealth == .danger)
    #expect(snapshot.sourceTint == HarnessMonitorTheme.danger)
  }

  @Test("reviewer summary maps to secondaryInk when no reviews yet")
  func reviewerSummaryNoReviewsUsesSecondaryInk() {
    let summary = DashboardReviewerSummary(reviews: [])
    #expect(summary.approvedCount == 0)
    #expect(summary.reviewerCount == 0)
    #expect(summary.tint == HarnessMonitorTheme.secondaryInk)
    #expect(summary.label == "0/0 approvals")
    #expect(summary.expandedTitle == "No reviews submitted yet")
  }

  @Test("reviewer summary maps partial approvals to accent")
  func reviewerSummaryPartialApprovalsUseAccent() {
    let summary = DashboardReviewerSummary(
      reviews: [
        PullRequestReview(author: "alice", state: .approved),
        PullRequestReview(author: "bob", state: .changesRequested),
      ]
    )
    #expect(summary.approvedCount == 1)
    #expect(summary.reviewerCount == 2)
    #expect(summary.tint == HarnessMonitorTheme.accent)
    #expect(summary.label == "1/2 approvals")
    #expect(summary.expandedTitle == "1 of 2 reviewers approved")
  }

  @Test("reviewer summary maps full approval to success")
  func reviewerSummaryFullApprovalUsesSuccess() {
    let summary = DashboardReviewerSummary(
      reviews: [
        PullRequestReview(author: "alice", state: .approved),
        PullRequestReview(author: "bob", state: .approved),
      ]
    )
    #expect(summary.approvedCount == 2)
    #expect(summary.reviewerCount == 2)
    #expect(summary.tint == HarnessMonitorTheme.success)
    #expect(summary.expandedTitle == "2 of 2 reviewers approved")
  }

  @Test("reviewer summary deduplicates repeat reviews from the same author")
  func reviewerSummaryDeduplicatesByAuthor() {
    // alice flipped from changesRequested -> approved; only the last
    // state should count toward the totals.
    let summary = DashboardReviewerSummary(
      reviews: [
        PullRequestReview(author: "alice", state: .changesRequested),
        PullRequestReview(author: "alice", state: .approved),
        PullRequestReview(author: "bob", state: .commented),
      ]
    )
    #expect(summary.reviewerCount == 2)
    #expect(summary.approvedCount == 1)
    #expect(summary.tint == HarnessMonitorTheme.accent)
  }

  @Test("reviewer summary zero-of-N still reads as secondaryInk")
  func reviewerSummaryZeroOfManyUsesSecondaryInk() {
    let summary = DashboardReviewerSummary(
      reviews: [
        PullRequestReview(author: "alice", state: .commented),
        PullRequestReview(author: "bob", state: .commented),
      ]
    )
    #expect(summary.approvedCount == 0)
    #expect(summary.reviewerCount == 2)
    #expect(summary.tint == HarnessMonitorTheme.secondaryInk)
    #expect(summary.expandedTitle == "0 of 2 reviewers approved")
  }

  @MainActor
  private func makeSnapshot(
    fetchedAt: String,
    fromCache: Bool,
    connectionState: HarnessMonitorStore.ConnectionState,
    health: DashboardReviewsSyncHealth,
    now: Date
  ) -> DashboardReviewsProvenanceSnapshot {
    DashboardReviewsProvenanceSnapshot(
      response: ReviewsQueryResponse(
        fetchedAt: fetchedAt,
        fromCache: fromCache,
        summary: ReviewsSummary(items: []),
        items: []
      ),
      connectionState: connectionState,
      syncHealth: health,
      cacheMaxAgeSeconds: 600,
      perRepositoryIntervalSeconds: 300,
      now: now
    )
  }
}
