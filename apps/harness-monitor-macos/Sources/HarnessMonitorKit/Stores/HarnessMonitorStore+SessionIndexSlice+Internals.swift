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
      self.rebuildProjection(change: .projection)
    }
  }

  func cancelPendingSearchRebuild() {
    searchRebuildTask?.cancel()
    searchRebuildTask = nil
  }

  func rebuildCatalogAndProjection(change: Change) {
    rebuildCatalog()
    rebuildProjection(change: change)
  }

  func rebuildCatalog() {
    debugCatalogRebuildCount += 1
    catalog.totalSessionCount = catalog.sessions.count
    catalog.totalOpenWorkCount = catalog.sessions.reduce(0) { $0 + $1.metrics.openTaskCount }
    catalog.totalBlockedCount = catalog.sessions.reduce(0) { $0 + $1.metrics.blockedTaskCount }
    catalog.sessionSummariesByID = Dictionary(
      uniqueKeysWithValues: catalog.sessions.map { ($0.sessionId, $0) }
    )

    sessionIndicesByID.removeAll(keepingCapacity: true)
    sessionRecordsByID.removeAll(keepingCapacity: true)

    for (index, summary) in catalog.sessions.enumerated() {
      sessionIndicesByID[summary.sessionId] = index
      sessionRecordsByID[summary.sessionId] = SessionRecord(summary: summary)
    }

    projectCatalogs = buildProjectCatalogs()
    rebuildOrderedSessionIDs()
    catalog.recentSessions = sortRecentSessions(catalog.sessions)
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
    if existingSummary.updatedAt != updatedSummary.updatedAt {
      catalog.recentSessions = sortRecentSessions(catalog.sessions)
    } else {
      catalog.recentSessions = replacingSession(updatedSummary, in: catalog.recentSessions)
    }
    if requiresOrderingRefresh(from: existingSummary, to: updatedSummary) {
      patchProjectCatalogOrderings(for: updatedSummary)
      rebuildOrderedSessionIDs()
    }
  }

  func buildProjectCatalogs() -> [ProjectCatalog] {
    var checkoutsByProject: [String: [String: CheckoutAccumulator]] = [:]

    for summary in catalog.sessions {
      let checkout = CheckoutAccumulator(
        checkoutId: summary.checkoutId,
        title: summary.checkoutDisplayName,
        isWorktree: summary.isWorktree,
        sessionIDs: [summary.sessionId]
      )

      if var existing = checkoutsByProject[summary.projectId]?[summary.checkoutId] {
        existing.sessionIDs.append(summary.sessionId)
        checkoutsByProject[summary.projectId]?[summary.checkoutId] = existing
      } else {
        checkoutsByProject[summary.projectId, default: [:]][summary.checkoutId] = checkout
      }
    }

    return catalog.projects.map { project in
      let checkouts = (checkoutsByProject[project.projectId] ?? [:]).values
        .map { checkout in
          CheckoutCatalog(
            checkoutId: checkout.checkoutId,
            title: checkout.title,
            isWorktree: checkout.isWorktree,
            recentActivitySessionIDs: sortedSessionIDs(
              checkout.sessionIDs,
              using: .recentActivity
            ),
            nameSessionIDs: sortedSessionIDs(
              checkout.sessionIDs,
              using: .name
            ),
            statusSessionIDs: sortedSessionIDs(
              checkout.sessionIDs,
              using: .status
            )
          )
        }
        .sorted { lhs, rhs in
          if lhs.isWorktree != rhs.isWorktree {
            return lhs.isWorktree == false
          }
          return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
      return ProjectCatalog(project: project, checkouts: checkouts)
    }
  }

  func rebuildOrderedSessionIDs() {
    orderedSessionIDsBySortOrder = Dictionary(
      uniqueKeysWithValues: SessionSortOrder.allCases.map { sortOrder in
        (
          sortOrder,
          projectCatalogs.flatMap { projectCatalog in
            projectCatalog.checkouts.flatMap { checkout in
              checkout.orderedSessionIDs(for: sortOrder)
            }
          }
        )
      }
    )
  }

  func rebuildProjection(change: Change) {
    searchRebuildTask?.cancel()
    searchRebuildTask = nil
    debugProjectionRebuildCount += 1
    queryTokens = Self.normalizedQueryTokens(for: controls.searchText)

    var visibleSessionIDSet = Set<String>()
    visibleSessionIDSet.reserveCapacity(sessionRecordsByID.count)
    for summary in catalog.sessions {
      if let record = sessionRecordsByID[summary.sessionId],
        matchesCurrentFilters(record)
      {
        visibleSessionIDSet.insert(summary.sessionId)
      }
    }
    let orderedVisibleSessionIDs = orderedVisibleSessionIDs(in: visibleSessionIDSet)
    let emptyState: HarnessMonitorStore.SidebarEmptyState
    if catalog.totalSessionCount == 0 {
      emptyState = .noSessions
    } else if orderedVisibleSessionIDs.isEmpty {
      emptyState = .noMatches
    } else {
      emptyState = .sessionsAvailable
    }

    if queryTokens.isEmpty {
      projection.apply(
        HarnessMonitorStore.SessionProjectionState(
          groupedSessions: buildGroupedSessions(visibleSessionIDSet: visibleSessionIDSet),
          filteredSessionCount: orderedVisibleSessionIDs.count,
          totalSessionCount: catalog.totalSessionCount,
          emptyState: emptyState
        )
      )
    }
    let nextSearchResults = HarnessMonitorStore.SessionSearchResultsState(
      presentation: HarnessMonitorStore.SessionSearchPresentationState(
        isSearchActive: !queryTokens.isEmpty,
        emptyState: emptyState
      ),
      filteredSessionCount: orderedVisibleSessionIDs.count,
      totalSessionCount: catalog.totalSessionCount,
      list: HarnessMonitorStore.SessionSearchResultsListState(
        visibleSessionIDs: orderedVisibleSessionIDs
      )
    )
    searchResults.apply(nextSearchResults)

    onChanged?(change)
  }

  func buildGroupedSessions(
    visibleSessionIDSet: Set<String>
  ) -> [HarnessMonitorStore.SessionGroup] {
    projectCatalogs.compactMap { projectCatalog -> HarnessMonitorStore.SessionGroup? in
      let checkoutGroups =
        projectCatalog.checkouts.compactMap { checkout -> HarnessMonitorStore.CheckoutGroup? in
          let checkoutSessionIDs =
            checkout
            .orderedSessionIDs(for: controls.sessionSortOrder)
            .filter { visibleSessionIDSet.contains($0) }
          guard !checkoutSessionIDs.isEmpty else {
            return nil
          }
          return HarnessMonitorStore.CheckoutGroup(
            checkoutId: checkout.checkoutId,
            title: checkout.title,
            isWorktree: checkout.isWorktree,
            sessionIDs: checkoutSessionIDs
          )
        }
      guard !checkoutGroups.isEmpty else {
        return nil
      }
      return HarnessMonitorStore.SessionGroup(
        project: projectCatalog.project,
        checkoutGroups: checkoutGroups
      )
    }
  }
}
