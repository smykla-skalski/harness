import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews reload recovery")
struct DashboardReviewsReloadRecoveryTests {
  @Test("missing cache and default empty response forces scheduler refresh")
  func missingCacheAndDefaultResponseForcesSchedulerRefresh() {
    #expect(
      dashboardReviewsShouldForceSchedulerRefresh(
        explicitForceRefresh: false,
        cacheApplied: false,
        response: emptyResponse(fetchedAt: "")
      )
    )
  }

  @Test("valid cached empty snapshot does not force scheduler refresh")
  func validCachedEmptySnapshotDoesNotForceSchedulerRefresh() {
    #expect(
      !dashboardReviewsShouldForceSchedulerRefresh(
        explicitForceRefresh: false,
        cacheApplied: true,
        response: emptyResponse(fetchedAt: "2026-05-25T11:48:00Z")
      )
    )
  }

  @Test("explicit user refresh still forces scheduler refresh")
  func explicitUserRefreshStillForcesSchedulerRefresh() {
    #expect(
      dashboardReviewsShouldForceSchedulerRefresh(
        explicitForceRefresh: true,
        cacheApplied: true,
        response: emptyResponse(fetchedAt: "2026-05-25T11:48:00Z")
      )
    )
  }

  private func emptyResponse(fetchedAt: String) -> ReviewsQueryResponse {
    ReviewsQueryResponse(
      fetchedAt: fetchedAt,
      fromCache: false,
      summary: ReviewsSummary(items: []),
      items: []
    )
  }
}
