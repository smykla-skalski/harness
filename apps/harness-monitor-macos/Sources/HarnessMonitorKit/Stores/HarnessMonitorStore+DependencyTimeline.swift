import Foundation

extension HarnessMonitorStore {
  /// Returns the per-PR observable timeline view model, creating one
  /// lazily on first access. The dictionary itself is
  /// `@ObservationIgnored` so adding a new entry doesn't invalidate
  /// every reader; only the returned view model's mutations propagate.
  public func dependencyUpdateTimelineViewModel(
    for pullRequestID: String
  ) -> DependencyUpdateTimelineViewModel {
    if let existing = dependencyUpdateTimelineViewModels[pullRequestID] {
      return existing
    }
    let created = DependencyUpdateTimelineViewModel()
    dependencyUpdateTimelineViewModels[pullRequestID] = created
    return created
  }

  /// Ensures the timeline for `item` is loaded into its view model.
  /// Cache-fresh paths short-circuit; otherwise marks
  /// `.loadingInitial` (or `.refreshing` when `forceRefresh: true`),
  /// fetches via the client, and publishes the drained page through
  /// `apply(initial:)`.
  ///
  /// Concurrent calls for the same PR collapse to one in-flight fetch
  /// via `pendingDependencyUpdateTimelineFetches`.
  public func prepareDependencyUpdateTimeline(
    for item: DependencyUpdateItem,
    forceRefresh: Bool = false
  ) async {
    let id = item.pullRequestID
    let viewModel = dependencyUpdateTimelineViewModel(for: id)
    if !forceRefresh && !viewModel.entries.isEmpty {
      return
    }
    let dedupeKey = "initial:\(id)"
    if pendingDependencyUpdateTimelineFetches.contains(dedupeKey) {
      return
    }
    pendingDependencyUpdateTimelineFetches.insert(dedupeKey)
    defer { pendingDependencyUpdateTimelineFetches.remove(dedupeKey) }

    viewModel.markLoading(forceRefresh ? .refreshing : .loadingInitial)

    guard let client else {
      viewModel.markFailed(reason: "Daemon unavailable")
      return
    }

    do {
      let response = try await client.fetchDependencyUpdateTimeline(
        request: DependencyUpdatesTimelineRequest(
          pullRequestId: id,
          cursor: nil,
          pageSize: 50,
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
  public func invalidateDependencyUpdateTimelines(for pullRequestIDs: [String]) {
    for id in pullRequestIDs {
      dependencyUpdateTimelineViewModels[id]?.clear()
    }
  }

  /// Loads the next older page using the view model's current
  /// `startCursor`. No-op when no older page exists, a load is
  /// already in flight, or the cursor is missing.
  public func loadOlderDependencyUpdateTimeline(for item: DependencyUpdateItem) async {
    let id = item.pullRequestID
    let viewModel = dependencyUpdateTimelineViewModel(for: id)
    guard viewModel.hasOlder, viewModel.loadState == .idle,
      let cursor = viewModel.startCursor
    else {
      return
    }
    let dedupeKey = "older:\(id):\(cursor)"
    if pendingDependencyUpdateTimelineFetches.contains(dedupeKey) {
      return
    }
    pendingDependencyUpdateTimelineFetches.insert(dedupeKey)
    defer { pendingDependencyUpdateTimelineFetches.remove(dedupeKey) }

    viewModel.markLoading(.loadingOlder)

    guard let client else {
      viewModel.markFailed(reason: "Daemon unavailable")
      return
    }

    do {
      let response = try await client.fetchDependencyUpdateTimeline(
        request: DependencyUpdatesTimelineRequest(
          pullRequestId: id,
          cursor: cursor,
          pageSize: 50,
          direction: .older
        )
      )
      viewModel.appendOlder(response)
    } catch {
      viewModel.markFailed(reason: error.localizedDescription)
    }
  }
}
