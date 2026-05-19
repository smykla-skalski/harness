extension HarnessMonitorStore.SessionIndexSlice {
  enum SummaryChangeImpact {
    case catalog
    case projection
    case summaryOnly
  }

  struct SessionRecord: Sendable {
    let summary: SessionSummary
    let normalizedSearchCorpus: String
    let normalizedName: String

    init(summary: SessionSummary) {
      self.summary = summary
      normalizedSearchCorpus = HarnessMonitorStore.SessionIndexSlice.normalizedSearchCorpus(
        for: summary
      )
      normalizedName = summary.displayTitle.sessionSearchNormalized
    }

    var statusSortKey: Int { summary.status.sortKey }
    var recentActivitySortKey: String { summary.updatedAt }
  }

  struct CheckoutCatalog: Sendable {
    let checkoutId: String
    let title: String
    let isWorktree: Bool
    let recentActivitySessionIDs: [String]
    let nameSessionIDs: [String]
    let statusSessionIDs: [String]

    func orderedSessionIDs(
      for sortOrder: SessionSortOrder
    ) -> [String] {
      switch sortOrder {
      case .recentActivity:
        recentActivitySessionIDs
      case .name:
        nameSessionIDs
      case .status:
        statusSessionIDs
      }
    }
  }

  struct CheckoutAccumulator: Sendable {
    let checkoutId: String
    let title: String
    let isWorktree: Bool
    var sessionIDs: [String]
  }

  struct ProjectCatalog: Sendable {
    let project: ProjectSummary
    let checkouts: [CheckoutCatalog]
  }

  struct ProjectionComputationInput: Sendable {
    let projectCatalogs: [ProjectCatalog]
    let sessionRecordsByID: [String: SessionRecord]
    let orderedSessionIDsBySortOrder: [SessionSortOrder: [String]]
    let sessionFilter: HarnessMonitorStore.SessionFilter
    let sessionFocusFilter: SessionFocusFilter
    let sessionSortOrder: SessionSortOrder
    let queryTokens: [String]
    let totalSessionCount: Int
  }

  struct ProjectionComputationOutput: Sendable {
    let queryTokens: [String]
    let projectionState: HarnessMonitorStore.SessionProjectionState?
    let searchResultsState: HarnessMonitorStore.SessionSearchResultsState
  }

  struct CatalogComputationInput: Sendable {
    let projects: [ProjectSummary]
    let sessions: [SessionSummary]
    let sessionFilter: HarnessMonitorStore.SessionFilter
    let sessionFocusFilter: SessionFocusFilter
    let sessionSortOrder: SessionSortOrder
    let queryTokens: [String]
  }

  struct CatalogComputationOutput: Sendable {
    let sessions: [SessionSummary]
    let totalSessionCount: Int
    let totalOpenWorkCount: Int
    let totalBlockedCount: Int
    let sessionIDs: Set<String>
    let sessionSummariesByID: [String: SessionSummary]
    let sessionIndicesByID: [String: Int]
    let recentSessionIndicesByID: [String: Int]
    let sessionRecordsByID: [String: SessionRecord]
    let projectCatalogs: [ProjectCatalog]
    let orderedSessionIDsBySortOrder: [SessionSortOrder: [String]]
    let recentSessions: [SessionSummary]
    let recentSessionIDs: [String]
    let projectionOutput: ProjectionComputationOutput
  }

  func orderedVisibleSessionIDs(in visibleSessionIDSet: Set<String>) -> [String] {
    orderedSessionIDsBySortOrder[controls.sessionSortOrder, default: []]
      .filter { visibleSessionIDSet.contains($0) }
  }

  nonisolated static func computeProjectionOutput(
    from input: ProjectionComputationInput
  ) -> ProjectionComputationOutput {
    var visibleSessionIDSet = Set<String>()
    visibleSessionIDSet.reserveCapacity(input.sessionRecordsByID.count)
    for record in input.sessionRecordsByID.values where matchesFilters(record, using: input) {
      visibleSessionIDSet.insert(record.summary.sessionId)
    }

    let orderedVisibleSessionIDs = orderedVisibleSessionIDs(
      in: visibleSessionIDSet,
      using: input
    )
    let emptyState: HarnessMonitorStore.SidebarEmptyState
    if input.totalSessionCount == 0 {
      emptyState = .noSessions
    } else if orderedVisibleSessionIDs.isEmpty {
      emptyState = .noMatches
    } else {
      emptyState = .sessionsAvailable
    }

    let projectionState: HarnessMonitorStore.SessionProjectionState?
    if input.queryTokens.isEmpty {
      projectionState = HarnessMonitorStore.SessionProjectionState(
        groupedSessions: buildGroupedSessions(
          from: input, visibleSessionIDSet: visibleSessionIDSet),
        filteredSessionCount: orderedVisibleSessionIDs.count,
        totalSessionCount: input.totalSessionCount,
        emptyState: emptyState
      )
    } else {
      projectionState = nil
    }

    return ProjectionComputationOutput(
      queryTokens: input.queryTokens,
      projectionState: projectionState,
      searchResultsState: HarnessMonitorStore.SessionSearchResultsState(
        presentation: HarnessMonitorStore.SessionSearchPresentationState(
          isSearchActive: !input.queryTokens.isEmpty,
          emptyState: emptyState
        ),
        filteredSessionCount: orderedVisibleSessionIDs.count,
        totalSessionCount: input.totalSessionCount,
        list: HarnessMonitorStore.SessionSearchResultsListState(
          visibleSessionIDs: orderedVisibleSessionIDs
        ),
        groupedSessions: buildGroupedSessions(
          from: input,
          visibleSessionIDSet: visibleSessionIDSet
        )
      )
    )
  }

  nonisolated static func computeCatalogOutput(
    from input: CatalogComputationInput
  ) -> CatalogComputationOutput {
    let sessions = deduplicatedSessions(input.sessions)
    var sessionIndicesByID: [String: Int] = [:]
    var sessionIDs: Set<String> = []
    var sessionRecordsByID: [String: SessionRecord] = [:]
    sessionIndicesByID.reserveCapacity(sessions.count)
    sessionIDs.reserveCapacity(sessions.count)
    sessionRecordsByID.reserveCapacity(sessions.count)

    for (index, summary) in sessions.enumerated() {
      sessionIDs.insert(summary.sessionId)
      sessionIndicesByID[summary.sessionId] = index
      sessionRecordsByID[summary.sessionId] = SessionRecord(summary: summary)
    }

    let projectCatalogs = buildProjectCatalogs(
      projects: input.projects,
      sessions: sessions,
      sessionRecordsByID: sessionRecordsByID
    )
    let orderedSessionIDsBySortOrder = orderedSessionIDsBySortOrder(from: projectCatalogs)
    let recentSessions = sortRecentSessions(sessions)
    let projectionInput = ProjectionComputationInput(
      projectCatalogs: projectCatalogs,
      sessionRecordsByID: sessionRecordsByID,
      orderedSessionIDsBySortOrder: orderedSessionIDsBySortOrder,
      sessionFilter: input.sessionFilter,
      sessionFocusFilter: input.sessionFocusFilter,
      sessionSortOrder: input.sessionSortOrder,
      queryTokens: input.queryTokens,
      totalSessionCount: sessions.count
    )

    return CatalogComputationOutput(
      sessions: sessions,
      totalSessionCount: sessions.count,
      totalOpenWorkCount: sessions.reduce(0) { $0 + $1.metrics.openTaskCount },
      totalBlockedCount: sessions.reduce(0) { $0 + $1.metrics.blockedTaskCount },
      sessionIDs: sessionIDs,
      sessionSummariesByID: Dictionary(
        uniqueKeysWithValues: sessions.map {
          ($0.sessionId, $0)
        }),
      sessionIndicesByID: sessionIndicesByID,
      recentSessionIndicesByID: Dictionary(
        uniqueKeysWithValues: recentSessions.enumerated().map { index, summary in
          (summary.sessionId, index)
        }
      ),
      sessionRecordsByID: sessionRecordsByID,
      projectCatalogs: projectCatalogs,
      orderedSessionIDsBySortOrder: orderedSessionIDsBySortOrder,
      recentSessions: recentSessions,
      recentSessionIDs: recentSessions.map(\.sessionId),
      projectionOutput: computeProjectionOutput(from: projectionInput)
    )
  }

  nonisolated static func matchesFilters(
    _ record: SessionRecord,
    using input: ProjectionComputationInput
  ) -> Bool {
    input.sessionFilter.includes(record.summary.status)
      && input.sessionFocusFilter.includes(record.summary)
      && searchMatches(record, queryTokens: input.queryTokens)
  }

  nonisolated static func searchMatches(
    _ record: SessionRecord,
    queryTokens: [String]
  ) -> Bool {
    guard !queryTokens.isEmpty else {
      return true
    }
    return queryTokens.allSatisfy(record.normalizedSearchCorpus.contains)
  }

  nonisolated static func orderedVisibleSessionIDs(
    in visibleSessionIDSet: Set<String>,
    using input: ProjectionComputationInput
  ) -> [String] {
    input.orderedSessionIDsBySortOrder[input.sessionSortOrder, default: []]
      .filter { visibleSessionIDSet.contains($0) }
  }

  nonisolated static func buildGroupedSessions(
    from input: ProjectionComputationInput,
    visibleSessionIDSet: Set<String>
  ) -> [HarnessMonitorStore.SessionGroup] {
    input.projectCatalogs.compactMap { projectCatalog -> HarnessMonitorStore.SessionGroup? in
      let checkoutGroups =
        projectCatalog.checkouts
        .compactMap { checkout -> HarnessMonitorStore.CheckoutGroup? in
          let checkoutSessionIDs =
            checkout
            .orderedSessionIDs(for: input.sessionSortOrder)
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

  func requiresCatalogRebuild(
    from existing: SessionSummary,
    to updated: SessionSummary
  ) -> Bool {
    existing.projectId != updated.projectId
      || existing.checkoutId != updated.checkoutId
      || existing.checkoutDisplayName != updated.checkoutDisplayName
      || existing.isWorktree != updated.isWorktree
  }

  func summaryChangeImpact(
    from existing: SessionSummary,
    to updated: SessionSummary
  ) -> SummaryChangeImpact {
    if requiresCatalogRebuild(from: existing, to: updated) {
      return .catalog
    }

    let existingRecord = SessionRecord(summary: existing)
    let updatedRecord = SessionRecord(summary: updated)
    let affectsProjection =
      existingRecord.normalizedSearchCorpus != updatedRecord.normalizedSearchCorpus
      || existingRecord.normalizedName != updatedRecord.normalizedName
      || existingRecord.statusSortKey != updatedRecord.statusSortKey
      || existingRecord.recentActivitySortKey != updatedRecord.recentActivitySortKey
      || existing.metrics.activeAgentCount != updated.metrics.activeAgentCount
      || existing.metrics.openTaskCount != updated.metrics.openTaskCount
      || existing.metrics.inProgressTaskCount != updated.metrics.inProgressTaskCount
      || existing.metrics.blockedTaskCount != updated.metrics.blockedTaskCount

    return affectsProjection ? .projection : .summaryOnly
  }

  nonisolated static func normalizedSearchCorpus(for summary: SessionSummary) -> String {
    [
      summary.projectName,
      summary.projectId,
      summary.sessionId,
      summary.worktreeDisplayName,
      summary.branchRef,
      summary.title,
      summary.context,
      summary.projectDir ?? "",
      summary.originPath,
      summary.worktreePath,
      summary.contextRoot,
      summary.leaderId ?? "",
      summary.observeId ?? "",
      summary.status.rawValue,
    ]
    .joined(separator: " ")
    .sessionSearchNormalized
  }

  nonisolated static func normalizedQueryTokens(for rawValue: String) -> [String] {
    rawValue.sessionSearchTokens
  }

  nonisolated static func sameArrayStorage<Element>(
    _ lhs: [Element],
    _ rhs: [Element]
  ) -> Bool {
    guard lhs.count == rhs.count else {
      return false
    }
    guard !lhs.isEmpty else {
      return true
    }
    return lhs.withUnsafeBufferPointer { lhsBuffer in
      rhs.withUnsafeBufferPointer { rhsBuffer in
        lhsBuffer.baseAddress == rhsBuffer.baseAddress
      }
    }
  }
}

actor SessionIndexWorker {
  func computeCatalog(
    from input: HarnessMonitorStore.SessionIndexSlice.CatalogComputationInput,
    delayNanoseconds: UInt64 = 0
  ) async -> HarnessMonitorStore.SessionIndexSlice.CatalogComputationOutput? {
    if delayNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: delayNanoseconds)
    }
    guard !Task.isCancelled else {
      return nil
    }
    return HarnessMonitorStore.SessionIndexSlice.computeCatalogOutput(from: input)
  }

  func computeProjection(
    from input: HarnessMonitorStore.SessionIndexSlice.ProjectionComputationInput,
    delayNanoseconds: UInt64 = 0
  ) async -> HarnessMonitorStore.SessionIndexSlice.ProjectionComputationOutput? {
    if delayNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: delayNanoseconds)
    }
    guard !Task.isCancelled else {
      return nil
    }
    return HarnessMonitorStore.SessionIndexSlice.computeProjectionOutput(from: input)
  }

  func waitForIdle() async {}
}
