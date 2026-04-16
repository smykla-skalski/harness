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
        )
      )
    )
  }

  func sortedSessionIDs(
    _ sessionIDs: [String],
    using sortOrder: SessionSortOrder
  ) -> [String] {
    sessionIDs.sorted { lhsID, rhsID in
      guard let lhs = sessionRecordsByID[lhsID],
        let rhs = sessionRecordsByID[rhsID]
      else {
        return lhsID < rhsID
      }

      switch sortOrder {
      case .recentActivity:
        if lhs.recentActivitySortKey != rhs.recentActivitySortKey {
          return lhs.recentActivitySortKey > rhs.recentActivitySortKey
        }
      case .name:
        let nameComparison = lhs.normalizedName.localizedStandardCompare(rhs.normalizedName)
        if nameComparison != .orderedSame {
          return nameComparison == .orderedAscending
        }
      case .status:
        if lhs.statusSortKey != rhs.statusSortKey {
          return lhs.statusSortKey < rhs.statusSortKey
        }
        if lhs.recentActivitySortKey != rhs.recentActivitySortKey {
          return lhs.recentActivitySortKey > rhs.recentActivitySortKey
        }
      }

      return lhs.summary.sessionId < rhs.summary.sessionId
    }
  }

  func sortRecentSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
    sessions.sorted { lhs, rhs in
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
      }
      return lhs.sessionId < rhs.sessionId
    }
  }

  func replacingSession(
    _ updatedSummary: SessionSummary,
    in sessions: [SessionSummary]
  ) -> [SessionSummary] {
    sessions.map { session in
      session.sessionId == updatedSummary.sessionId ? updatedSummary : session
    }
  }

  func matchesCurrentFilters(_ record: SessionRecord) -> Bool {
    controls.sessionFilter.includes(record.summary.status)
      && controls.sessionFocusFilter.includes(record.summary)
      && searchMatches(record)
  }

  func searchMatches(_ record: SessionRecord) -> Bool {
    guard !queryTokens.isEmpty else {
      return true
    }
    return queryTokens.allSatisfy(record.normalizedSearchCorpus.contains)
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
      || existing.isWorktree != updated.isWorktree
      || existing.worktreeName != updated.worktreeName
      || existing.checkoutRoot != updated.checkoutRoot
  }

  func requiresOrderingRefresh(
    from existing: SessionSummary,
    to updated: SessionSummary
  ) -> Bool {
    let existingRecord = SessionRecord(summary: existing)
    let updatedRecord = SessionRecord(summary: updated)
    return existingRecord.normalizedName != updatedRecord.normalizedName
      || existingRecord.statusSortKey != updatedRecord.statusSortKey
      || existingRecord.recentActivitySortKey != updatedRecord.recentActivitySortKey
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

  func patchProjectCatalogOrderings(
    for updatedSummary: SessionSummary
  ) {
    guard
      let projectIndex = projectCatalogs.firstIndex(where: {
        $0.project.projectId == updatedSummary.projectId
      })
    else {
      return
    }
    guard
      let checkoutIndex = projectCatalogs[projectIndex].checkouts.firstIndex(where: {
        $0.checkoutId == updatedSummary.checkoutId
      })
    else {
      return
    }

    let projectCatalog = projectCatalogs[projectIndex]
    let checkout = projectCatalog.checkouts[checkoutIndex]
    let memberSessionIDs = checkout.recentActivitySessionIDs

    var updatedCheckouts = projectCatalog.checkouts
    updatedCheckouts[checkoutIndex] = CheckoutCatalog(
      checkoutId: checkout.checkoutId,
      title: checkout.title,
      isWorktree: checkout.isWorktree,
      recentActivitySessionIDs: sortedSessionIDs(
        memberSessionIDs,
        using: .recentActivity
      ),
      nameSessionIDs: sortedSessionIDs(
        memberSessionIDs,
        using: .name
      ),
      statusSessionIDs: sortedSessionIDs(
        memberSessionIDs,
        using: .status
      )
    )

    var updatedProjectCatalogs = projectCatalogs
    updatedProjectCatalogs[projectIndex] = ProjectCatalog(
      project: projectCatalog.project,
      checkouts: updatedCheckouts
    )
    projectCatalogs = updatedProjectCatalogs
  }

  nonisolated static func normalizedSearchCorpus(for summary: SessionSummary) -> String {
    [
      summary.projectName,
      summary.projectId,
      summary.checkoutId,
      summary.checkoutDisplayName,
      summary.sessionId,
      summary.title,
      summary.context,
      summary.projectDir ?? "",
      summary.checkoutRoot,
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
}
