extension SessionTimelineView {
  var currentTimelineScrollCommand: SessionTimelineScrollCommand? {
    get { scrollCommand }
    nonmutating set { scrollCommand = newValue }
  }

  var currentTimelineScrollCommandGeneration: Int {
    get { scrollCommandGeneration }
    nonmutating set { scrollCommandGeneration = newValue }
  }

  var currentPendingNavigation: SessionTimelinePendingNavigation? {
    get { pendingNavigationAfterLoad }
    nonmutating set { pendingNavigationAfterLoad = newValue }
  }

  var currentPendingNavigationGeneration: Int {
    get { pendingNavigationGeneration }
    nonmutating set { pendingNavigationGeneration = newValue }
  }

  var currentPendingEdgeLoad: SessionTimelinePendingEdgeLoad? {
    get { pendingEdgeLoad }
    nonmutating set { pendingEdgeLoad = newValue }
  }

  var timelineViewport: SessionTimelineViewportModel {
    viewport
  }

  var currentFilterPersistenceMode: SessionTimelineFilterPersistenceMode {
    filterPersistenceMode
  }

  var currentFilters: SessionTimelineFilterState {
    get { filters }
    nonmutating set { filters = newValue }
  }

  var currentAppStoredFilterStateRawValue: String {
    get { appStoredFilterStateRawValue }
    nonmutating set { appStoredFilterStateRawValue = newValue }
  }

  var currentSceneStoredFilterRegistryRawValue: String {
    get { sceneStoredFilterRegistryRawValue }
    nonmutating set { sceneStoredFilterRegistryRawValue = newValue }
  }
}
