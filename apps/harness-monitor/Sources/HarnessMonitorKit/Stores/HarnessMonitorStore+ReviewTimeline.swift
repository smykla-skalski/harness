import Foundation

extension HarnessMonitorStore {
  /// Returns the per-PR observable timeline view model, creating one
  /// lazily on first access. The dictionary itself is
  /// `@ObservationIgnored` so adding a new entry doesn't invalidate
  /// every reader; only the returned view model's mutations propagate.
  public func reviewTimelineViewModel(
    for pullRequestID: String
  ) -> ReviewTimelineViewModel {
    if let existing = reviewTimelineViewModels[pullRequestID] {
      return existing
    }
    let created = ReviewTimelineViewModel()
    reviewTimelineViewModels[pullRequestID] = created
    return created
  }

  /// Ensures the timeline for `item` is loaded into its view model.
  /// Cache-fresh paths short-circuit; otherwise marks
  /// `.loadingInitial` (or `.refreshing` when `forceRefresh: true`),
  /// fetches via the client, and publishes the drained page through
  /// `apply(initial:)`.
  ///
  /// Concurrent calls for the same PR collapse to one in-flight fetch
  /// via `pendingReviewTimelineFetches`.
  public func prepareReviewTimeline(
    for item: ReviewItem,
    forceRefresh: Bool = false,
    pageSize: UInt32 = 50
  ) async {
    let id = item.pullRequestID
    let viewModel = reviewTimelineViewModel(for: id)
    if !forceRefresh && !viewModel.entries.isEmpty {
      return
    }
    let dedupeKey = "initial:\(id)"
    if pendingReviewTimelineFetches.contains(dedupeKey) {
      return
    }
    pendingReviewTimelineFetches.insert(dedupeKey)
    defer { pendingReviewTimelineFetches.remove(dedupeKey) }

    viewModel.markLoading(forceRefresh ? .refreshing : .loadingInitial)

    guard let client else {
      viewModel.markFailed(reason: "Daemon unavailable")
      return
    }

    do {
      let interval = ReviewTimelinePerf.beginDaemonFetch(
        pullRequestID: id,
        direction: forceRefresh ? "refresh" : "initial"
      )
      defer { ReviewTimelinePerf.end(interval) }
      let response = try await client.fetchReviewTimeline(
        request: ReviewsTimelineRequest(
          pullRequestId: id,
          cursor: nil,
          pageSize: Self.normalizedReviewTimelinePageSize(pageSize),
          direction: .older,
          forceRefresh: forceRefresh
        )
      )
      viewModel.apply(initial: response)
    } catch {
      viewModel.markFailed(reason: error.localizedDescription)
    }
  }

  /// Invalidates the cached timeline for each pull-request id by
  /// clearing its view model's entries. Used by the route-level
  /// affected-refresh hook after a daemon-side mutation (approve,
  /// merge, comment, rerun, labels): the next detail-pane visit for
  /// the affected PR triggers a fresh fetch instead of showing the
  /// stale chronological state.
  ///
  /// View models for PRs not in the list are untouched.
  public func invalidateReviewTimelines(for pullRequestIDs: [String]) {
    for id in pullRequestIDs {
      reviewTimelineViewModels[id]?.clear()
    }
  }

  /// Loads the next older page using the view model's current
  /// `startCursor`. No-op when no older page exists, a load is
  /// already in flight, or the cursor is missing.
  public func loadOlderReviewTimeline(
    for item: ReviewItem,
    pageSize: UInt32 = 50
  ) async {
    let id = item.pullRequestID
    let viewModel = reviewTimelineViewModel(for: id)
    guard viewModel.hasOlder, viewModel.loadState == .idle,
      let cursor = viewModel.startCursor
    else {
      return
    }
    let dedupeKey = "older:\(id):\(cursor)"
    if pendingReviewTimelineFetches.contains(dedupeKey) {
      return
    }
    pendingReviewTimelineFetches.insert(dedupeKey)
    defer { pendingReviewTimelineFetches.remove(dedupeKey) }

    viewModel.markLoading(.loadingOlder)

    guard let client else {
      viewModel.markFailed(reason: "Daemon unavailable")
      return
    }

    do {
      let interval = ReviewTimelinePerf.beginDaemonFetch(
        pullRequestID: id,
        direction: "older"
      )
      defer { ReviewTimelinePerf.end(interval) }
      let response = try await client.fetchReviewTimeline(
        request: ReviewsTimelineRequest(
          pullRequestId: id,
          cursor: cursor,
          pageSize: Self.normalizedReviewTimelinePageSize(pageSize),
          direction: .older
        )
      )
      viewModel.appendOlder(response)
    } catch {
      viewModel.markFailed(reason: error.localizedDescription)
    }
  }

  private static func normalizedReviewTimelinePageSize(_ pageSize: UInt32) -> UInt32 {
    min(max(pageSize, 10), 100)
  }
}
