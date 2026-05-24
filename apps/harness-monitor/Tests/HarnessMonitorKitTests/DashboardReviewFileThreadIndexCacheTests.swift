import HarnessMonitorKit
import Testing

@testable import HarnessMonitorUIPreviewable

@Suite("Dashboard review file thread index cache")
struct DashboardReviewFileThreadIndexCacheTests {
  @MainActor
  @Test("cache rebuilds when timeline revision changes")
  func cacheRebuildsWhenTimelineRevisionChanges() {
    let timeline = ReviewTimelineViewModel()
    let cache = DashboardReviewFileThreadIndexCache()
    let path = "Sources/File.swift"

    #expect(cache.index(for: timeline).anchors(forPath: path).isEmpty)

    timeline.apply(
      initial: response(entries: [reviewThread(id: "thread-1", path: path, resolved: false)])
    )

    let unresolved = cache.index(for: timeline)
    #expect(unresolved.hasUnresolvedAnchors(forPath: path))
    #expect(cache.index(for: timeline) == unresolved)

    timeline.updateReviewThreadResolved(threadID: "thread-1", resolved: true)

    let resolved = cache.index(for: timeline)
    #expect(!resolved.hasUnresolvedAnchors(forPath: path))
    #expect(resolved.unresolvedAnchorCount(forPath: path) == 0)
  }

  private func response(entries: [ReviewTimelineEntry]) -> ReviewsTimelineResponse {
    ReviewsTimelineResponse(
      pullRequestId: "PR_thread_index",
      entries: entries,
      pageInfo: ReviewTimelinePageInfo(
        startCursor: nil,
        endCursor: "end",
        hasOlder: false,
        hasNewer: false
      ),
      viewerCanComment: true,
      fetchedAt: "2026-05-24T10:00:00Z"
    )
  }

  private func reviewThread(
    id: String,
    path: String,
    resolved: Bool
  ) -> ReviewTimelineEntry {
    .reviewThread(
      ReviewThreadPayload(
        id: id,
        createdAt: "2026-05-24T10:00:00Z",
        isResolved: resolved,
        path: path,
        line: 2,
        diffSide: "RIGHT",
        comments: [
          ReviewThreadCommentPayload(
            id: "\(id)-comment",
            body: "Please rename this value.",
            createdAt: "2026-05-24T10:00:00Z"
          )
        ]
      )
    )
  }
}
