import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard reviews disappeared item tracker")
struct DashboardReviewsDisappearedItemTrackerTests {
  @Test("first diff is the baseline and returns no descriptors")
  func firstDiffEstablishesBaseline() {
    var tracker = DashboardReviewsDisappearedItemTracker()
    let items = [makeItem(pullRequestID: "PR_1", repository: "acme/api", number: 12)]

    let descriptors = tracker.diff(currentItems: items)

    #expect(descriptors.isEmpty)
  }

  @Test("empty current items on first call still returns no descriptors")
  func emptyFirstCallReturnsNoDescriptors() {
    var tracker = DashboardReviewsDisappearedItemTracker()
    let descriptors = tracker.diff(currentItems: [])
    #expect(descriptors.isEmpty)
  }

  @Test("a removed item is surfaced with its previous snapshot")
  func removedItemSurfacesPreviousSnapshot() {
    var tracker = DashboardReviewsDisappearedItemTracker()
    let first = [
      makeItem(pullRequestID: "PR_1", repository: "acme/api", number: 12, title: "Bump dep"),
      makeItem(pullRequestID: "PR_2", repository: "acme/api", number: 13, state: .merged),
    ]
    _ = tracker.diff(currentItems: first)

    let second = tracker.diff(currentItems: [first[0]])

    #expect(second.count == 1)
    #expect(second.first?.snapshot.pullRequestID == "PR_2")
    #expect(second.first?.snapshot.lastSeenState == .merged)
    #expect(second.first?.toastMessage == "PR #13 in acme/api merged - removed from list")
  }

  @Test("removing several items returns each in repo-then-number order")
  func multipleRemovalsAreSorted() {
    var tracker = DashboardReviewsDisappearedItemTracker()
    let baseline = [
      makeItem(pullRequestID: "PR_a", repository: "zeta/util", number: 99, state: .closed),
      makeItem(pullRequestID: "PR_b", repository: "acme/web", number: 2),
      makeItem(pullRequestID: "PR_c", repository: "acme/web", number: 1, state: .merged),
    ]
    _ = tracker.diff(currentItems: baseline)

    let descriptors = tracker.diff(currentItems: [])

    #expect(descriptors.map(\.snapshot.pullRequestID) == ["PR_c", "PR_b", "PR_a"])
  }

  @Test("an open PR that disappears reads as removed from list")
  func openPullRequestUsesRemovedCopy() {
    var tracker = DashboardReviewsDisappearedItemTracker()
    let first = [makeItem(pullRequestID: "PR_1", repository: "acme/api", number: 8)]
    _ = tracker.diff(currentItems: first)

    let descriptors = tracker.diff(currentItems: [])

    #expect(descriptors.first?.toastMessage == "PR #8 in acme/api removed from list")
  }

  @Test("descriptor builds an audit-only notification history entry")
  func descriptorBuildsAuditOnlyNotificationHistoryEntry() {
    let descriptor = DashboardReviewsDisappearedItemTracker.Descriptor(
      snapshot: .init(
        pullRequestID: "PR_9",
        repository: "acme/api",
        number: 9,
        title: "Prune stale branch",
        lastSeenState: .merged
      )
    )
    let recordedAt = Date(timeIntervalSince1970: 1_717_000_000)

    let entry = descriptor.notificationHistoryEntry(recordedAt: recordedAt)

    #expect(entry.id == "reviews-disappeared-PR_9-1717000000")
    #expect(entry.recordedAt == recordedAt)
    #expect(entry.updatedAt == recordedAt)
    #expect(entry.source == .toast)
    #expect(entry.severity == .info)
    #expect(entry.status == .dismissed)
    #expect(entry.statusText == "Captured for audit only")
    #expect(entry.title == "Review removed from list")
    #expect(entry.message == "PR #9 in acme/api merged - removed from list")
    #expect(entry.actions.isEmpty)
    #expect(entry.repeatCount == 1)
  }

  @Test("reset drops the baseline so the next diff is silent")
  func resetDropsBaseline() {
    var tracker = DashboardReviewsDisappearedItemTracker()
    _ = tracker.diff(currentItems: [
      makeItem(pullRequestID: "PR_1", repository: "acme/api", number: 8)
    ])

    tracker.reset()
    let descriptors = tracker.diff(currentItems: [])

    #expect(descriptors.isEmpty)
  }

  @Test("repeated diff with no change returns no descriptors")
  func repeatedSameDiffReturnsEmpty() {
    var tracker = DashboardReviewsDisappearedItemTracker()
    let items = [makeItem(pullRequestID: "PR_1", repository: "acme/api", number: 5)]
    _ = tracker.diff(currentItems: items)
    let descriptors = tracker.diff(currentItems: items)
    #expect(descriptors.isEmpty)
  }

  @Test("diff avoids transient current ID collections")
  func diffAvoidsTransientCurrentIDCollections() throws {
    let source = try dashboardReviewsRouteSource(
      named: "DashboardReviewsDisappearedItemTracker.swift"
    )

    #expect(source.contains("nextSnapshots.reserveCapacity(currentItems.count)"))
    #expect(source.contains("nextSnapshots[snapshot.pullRequestID] == nil"))
    #expect(!source.contains("Set(currentItems.map(\\.pullRequestID))"))
    #expect(!source.contains("currentItems.map(\\.pullRequestID)"))
    #expect(!source.contains("let removedIDs"))
    #expect(!source.contains("removedIDs.compactMap"))
  }

  @Test("route view records disappeared descriptors into notification history instead of inline state")
  func routeViewRecordsDisappearedDescriptorsIntoNotificationHistory() throws {
    let source = try dashboardReviewsRouteSource(named: "DashboardReviewsRouteView.swift")

    #expect(source.contains("store.recordNotificationHistoryEntry("))
    #expect(!source.contains("routeState.disappearedDescriptors.append(contentsOf: descriptors)"))
  }

  @Test("transient banner source keeps only the refresh-timeout banner")
  func transientBannerSourceKeepsOnlyRefreshTimeoutBanner() throws {
    let source = try dashboardReviewsRouteSource(
      named: "DashboardReviewsRouteView+TransientBanners.swift"
    )

    #expect(source.contains("if routeRefreshTimeoutItems != nil"))
    #expect(!source.contains("routeDisappearedDescriptors"))
    #expect(!source.contains("disappearedItemBanner("))
  }

  private func makeItem(
    pullRequestID: String,
    repository: String,
    number: UInt64,
    title: String = "Sample",
    state: ReviewPullRequestState = .open
  ) -> ReviewItem {
    ReviewItem(
      pullRequestID: pullRequestID,
      repositoryID: repository,
      repository: repository,
      number: number,
      title: title,
      url: "https://example.com/\(pullRequestID)",
      authorLogin: "octocat",
      state: state,
      mergeable: .mergeable,
      reviewStatus: .none,
      checkStatus: .none,
      policyBlocked: false,
      isDraft: false,
      headSha: "deadbeef",
      labels: [],
      checks: [],
      reviews: [],
      additions: 1,
      deletions: 0,
      createdAt: "2026-05-01T09:00:00Z",
      updatedAt: "2026-05-01T09:00:00Z",
      requiredFailedCheckNames: [],
      viewerCanUpdate: true,
      viewerCanMergeAsAdmin: false
    )
  }
}
