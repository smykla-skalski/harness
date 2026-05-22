struct DependencyUpdateStoreState {
  let bodies = DependencyUpdateBodyStore()
  var pendingBodyFetches: Set<String> = []
  var timelineViewModels: [String: DependencyUpdateTimelineViewModel] = [:]
  var pendingTimelineFetches: Set<String> = []
  var draftWriteTasks: [String: Task<Void, Never>] = [:]
  var pendingBodyEdits: [String: PendingDependencyUpdateBodyEdit] = [:]
}

extension HarnessMonitorStore {
  public var dependencyUpdateBodies: DependencyUpdateBodyStore {
    dependencyUpdates.bodies
  }

  var pendingDependencyUpdateBodyFetches: Set<String> {
    get { dependencyUpdates.pendingBodyFetches }
    set { dependencyUpdates.pendingBodyFetches = newValue }
  }

  var dependencyUpdateTimelineViewModels: [String: DependencyUpdateTimelineViewModel] {
    get { dependencyUpdates.timelineViewModels }
    set { dependencyUpdates.timelineViewModels = newValue }
  }

  var pendingDependencyUpdateTimelineFetches: Set<String> {
    get { dependencyUpdates.pendingTimelineFetches }
    set { dependencyUpdates.pendingTimelineFetches = newValue }
  }

  var dependencyUpdateDraftWriteTasks: [String: Task<Void, Never>] {
    get { dependencyUpdates.draftWriteTasks }
    set { dependencyUpdates.draftWriteTasks = newValue }
  }

  var pendingDependencyUpdateBodyEdits: [String: PendingDependencyUpdateBodyEdit] {
    get { dependencyUpdates.pendingBodyEdits }
    set { dependencyUpdates.pendingBodyEdits = newValue }
  }
}
