struct ReviewStoreState {
  let bodies = ReviewBodyStore()
  var pendingBodyFetches: Set<String> = []
  var timelineViewModels: [String: ReviewTimelineViewModel] = [:]
  var pendingTimelineFetches: Set<String> = []
  /// Reference counts of detail-pane subscribers per pull-request ID. The
  /// route's affected-refresh invalidation guard only clears timelines whose
  /// count is greater than zero (i.e. a detail pane has registered for
  /// updates); refresh paths skip invalidation for PRs that aren't being
  /// observed, avoiding a redundant fetch on the next visit.
  var timelineSubscriptionCounts: [String: Int] = [:]
  var draftWriteTasks: [String: Task<Void, Never>] = [:]
  var pendingBodyEdits: [String: PendingReviewBodyEdit] = [:]
}

extension HarnessMonitorStore {
  public var reviewBodies: ReviewBodyStore {
    reviews.bodies
  }

  var pendingReviewBodyFetches: Set<String> {
    get { reviews.pendingBodyFetches }
    set { reviews.pendingBodyFetches = newValue }
  }

  var reviewTimelineViewModels: [String: ReviewTimelineViewModel] {
    get { reviews.timelineViewModels }
    set { reviews.timelineViewModels = newValue }
  }

  var pendingReviewTimelineFetches: Set<String> {
    get { reviews.pendingTimelineFetches }
    set { reviews.pendingTimelineFetches = newValue }
  }

  /// Pull-request IDs whose detail-pane subscribers are currently observing
  /// timeline updates. The set is derived from `timelineSubscriptionCounts`
  /// so callers see a stable read-only view without exposing the counter
  /// itself.
  public var activeTimelineSubscriptions: Set<String> {
    Set(reviews.timelineSubscriptionCounts.keys)
  }

  /// Increments the detail-pane subscription count for `pullRequestID`.
  /// Detail panes call this on appear so the route-level affected-refresh
  /// hook knows whose timeline is currently visible. Multiple panes for the
  /// same PR are supported via reference counting.
  public func registerTimelineSubscription(pullRequestID: String) {
    let next = (reviews.timelineSubscriptionCounts[pullRequestID] ?? 0) + 1
    reviews.timelineSubscriptionCounts[pullRequestID] = next
  }

  /// Decrements the detail-pane subscription count for `pullRequestID` and
  /// removes the entry when it reaches zero. Calling this without a matching
  /// `register` is a no-op so view-lifecycle ordering edge cases don't
  /// underflow.
  public func unregisterTimelineSubscription(pullRequestID: String) {
    guard let current = reviews.timelineSubscriptionCounts[pullRequestID] else {
      return
    }
    let next = current - 1
    if next <= 0 {
      reviews.timelineSubscriptionCounts.removeValue(forKey: pullRequestID)
    } else {
      reviews.timelineSubscriptionCounts[pullRequestID] = next
    }
  }

  var reviewDraftWriteTasks: [String: Task<Void, Never>] {
    get { reviews.draftWriteTasks }
    set { reviews.draftWriteTasks = newValue }
  }

  var pendingReviewBodyEdits: [String: PendingReviewBodyEdit] {
    get { reviews.pendingBodyEdits }
    set { reviews.pendingBodyEdits = newValue }
  }
}
