import Foundation

extension HarnessMonitorStore.SessionIndexSlice {
  func refreshCatalogIfNeeded(
    _ changed: Bool,
    projects: [ProjectSummary],
    sessions: [SessionSummary]
  ) {
    guard changed, !suppressRefresh else {
      return
    }

    suppressRefresh = true
    catalog.projects = projects
    catalog.sessions = sessions
    suppressRefresh = false
    rebuildCatalogAndProjection(change: .snapshot)
  }

  func updateSearchText(_ newValue: String) {
    guard controls.searchText != newValue else {
      return
    }
    let didChangeQuery =
      Self.normalizedQueryTokens(for: controls.searchText)
      != Self.normalizedQueryTokens(for: newValue)
    controls.searchText = newValue
    guard didChangeQuery, !suppressRefresh else {
      return
    }
    scheduleSearchRebuild(for: newValue)
  }

  func updateSessionFilter(_ newValue: HarnessMonitorStore.SessionFilter) {
    guard controls.sessionFilter != newValue else {
      return
    }
    controls.sessionFilter = newValue
    refreshProjectionIfNeeded(true)
  }

  func updateSessionFocusFilter(_ newValue: SessionFocusFilter) {
    guard controls.sessionFocusFilter != newValue else {
      return
    }
    controls.sessionFocusFilter = newValue
    refreshProjectionIfNeeded(true)
  }

  func updateSessionSortOrder(_ newValue: SessionSortOrder) {
    guard controls.sessionSortOrder != newValue else {
      return
    }
    controls.sessionSortOrder = newValue
    refreshProjectionIfNeeded(true)
  }

  func refreshProjectionIfNeeded(_ changed: Bool) {
    guard changed, !suppressRefresh else {
      return
    }
    cancelPendingSearchRebuild()
    rebuildProjection(change: .projection)
  }

  func scheduleSearchRebuild(for targetSearchText: String) {
    searchRebuildTask?.cancel()
    searchRebuildTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: Self.searchRebuildDebounceNanoseconds)
      guard !Task.isCancelled, let self else {
        return
      }
      guard self.controls.searchText == targetSearchText else {
        return
      }
      self.rebuildProjectionAsync(change: .projection)
    }
  }

  func cancelPendingSearchRebuild() {
    searchRebuildTask?.cancel()
    searchRebuildTask = nil
  }

  func cancelPendingProjectionRebuild() {
    projectionComputationTask?.cancel()
    projectionComputationTask = nil
  }

  func advanceProjectionGeneration() -> UInt64 {
    projectionGeneration &+= 1
    return projectionGeneration
  }

  func projectionComputationInput() -> ProjectionComputationInput {
    ProjectionComputationInput(
      projectCatalogs: projectCatalogs,
      sessionRecordsByID: sessionRecordsByID,
      orderedSessionIDsBySortOrder: orderedSessionIDsBySortOrder,
      sessionFilter: controls.sessionFilter,
      sessionFocusFilter: controls.sessionFocusFilter,
      sessionSortOrder: controls.sessionSortOrder,
      queryTokens: Self.normalizedQueryTokens(for: controls.searchText),
      totalSessionCount: catalog.totalSessionCount
    )
  }

  func catalogComputationInput() -> CatalogComputationInput {
    CatalogComputationInput(
      projects: catalog.projects,
      sessions: catalog.sessions,
      sessionFilter: controls.sessionFilter,
      sessionFocusFilter: controls.sessionFocusFilter,
      sessionSortOrder: controls.sessionSortOrder,
      queryTokens: Self.normalizedQueryTokens(for: controls.searchText)
    )
  }

  func applyProjectionOutput(
    _ output: ProjectionComputationOutput,
    change: Change
  ) {
    queryTokens = output.queryTokens
    if let projectionState = output.projectionState {
      projection.apply(projectionState)
    }
    searchResults.apply(output.searchResultsState)
    onChanged?(change)
  }

  func applyCatalogOutput(
    _ output: CatalogComputationOutput,
    change: Change
  ) {
    catalog.totalSessionCount = output.totalSessionCount
    catalog.totalOpenWorkCount = output.totalOpenWorkCount
    catalog.totalBlockedCount = output.totalBlockedCount
    catalog.sessionSummariesByID = output.sessionSummariesByID
    catalog.recentSessions = output.recentSessions
    sessionIndicesByID = output.sessionIndicesByID
    recentSessionIndicesByID = output.recentSessionIndicesByID
    sessionRecordsByID = output.sessionRecordsByID
    projectCatalogs = output.projectCatalogs
    orderedSessionIDsBySortOrder = output.orderedSessionIDsBySortOrder
    applyProjectionOutput(output.projectionOutput, change: change)
  }

  func rebuildProjectionAsync(change: Change) {
    searchRebuildTask?.cancel()
    searchRebuildTask = nil
    cancelPendingProjectionRebuild()

    let generation = advanceProjectionGeneration()
    let request = projectionComputationInput()
    let delayNanoseconds = debugProjectionDelayNanoseconds

    projectionComputationTask = Task { @MainActor [weak self] in
      let output = await self?.sessionIndexWorker.computeProjection(
        from: request,
        delayNanoseconds: delayNanoseconds
      )

      guard !Task.isCancelled, let self, let output else {
        return
      }
      guard self.projectionGeneration == generation else {
        return
      }

      self.debugProjectionRebuildCount += 1
      self.applyProjectionOutput(output, change: change)
      self.projectionComputationTask = nil
    }
  }

  func rebuildCatalogAndProjection(change: Change) {
    searchRebuildTask?.cancel()
    searchRebuildTask = nil
    cancelPendingProjectionRebuild()

    let generation = advanceProjectionGeneration()
    let request = catalogComputationInput()
    let delayNanoseconds = debugProjectionDelayNanoseconds

    projectionComputationTask = Task { @MainActor [weak self] in
      let output = await self?.sessionIndexWorker.computeCatalog(
        from: request,
        delayNanoseconds: delayNanoseconds
      )

      guard !Task.isCancelled, let self, let output else {
        return
      }
      guard self.projectionGeneration == generation else {
        return
      }

      self.debugCatalogRebuildCount += 1
      self.debugProjectionRebuildCount += 1
      self.applyCatalogOutput(output, change: change)
      self.projectionComputationTask = nil
    }
  }

  func patchCatalog(
    existingSummary: SessionSummary,
    updatedSummary: SessionSummary
  ) {
    catalog.sessionSummariesByID[updatedSummary.sessionId] = updatedSummary
    sessionRecordsByID[updatedSummary.sessionId] = SessionRecord(summary: updatedSummary)
    catalog.totalOpenWorkCount +=
      updatedSummary.metrics.openTaskCount
      - existingSummary.metrics.openTaskCount
    catalog.totalBlockedCount +=
      updatedSummary.metrics.blockedTaskCount
      - existingSummary.metrics.blockedTaskCount
    if let recentIndex = recentSessionIndicesByID[updatedSummary.sessionId],
      catalog.recentSessions.indices.contains(recentIndex)
    {
      catalog.recentSessions[recentIndex] = updatedSummary
    }
  }

  func rebuildProjection(change: Change) {
    searchRebuildTask?.cancel()
    searchRebuildTask = nil
    rebuildProjectionAsync(change: change)
  }

}
