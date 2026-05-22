struct ReviewStoreState {
  let bodies = ReviewBodyStore()
  var pendingBodyFetches: Set<String> = []
  var timelineViewModels: [String: ReviewTimelineViewModel] = [:]
  var pendingTimelineFetches: Set<String> = []
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

  var reviewDraftWriteTasks: [String: Task<Void, Never>] {
    get { reviews.draftWriteTasks }
    set { reviews.draftWriteTasks = newValue }
  }

  var pendingReviewBodyEdits: [String: PendingReviewBodyEdit] {
    get { reviews.pendingBodyEdits }
    set { reviews.pendingBodyEdits = newValue }
  }
}
