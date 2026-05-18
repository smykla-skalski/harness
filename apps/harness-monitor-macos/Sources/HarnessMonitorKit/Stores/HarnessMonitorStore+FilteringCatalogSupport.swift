extension HarnessMonitorStore.SessionIndexSlice {
  nonisolated static func deduplicatedSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
    var seenSessionIDs = Set<String>()
    seenSessionIDs.reserveCapacity(sessions.count)

    for summary in sessions where !seenSessionIDs.insert(summary.sessionId).inserted {
      return sessionsDeduplicatedAfterCollision(sessions)
    }

    return sessions
  }

  nonisolated private static func sessionsDeduplicatedAfterCollision(
    _ sessions: [SessionSummary]
  ) -> [SessionSummary] {
    var lastIndexBySessionID: [String: Int] = [:]
    lastIndexBySessionID.reserveCapacity(sessions.count)

    for (index, summary) in sessions.enumerated() {
      lastIndexBySessionID[summary.sessionId] = index
    }

    var deduplicated: [SessionSummary] = []
    deduplicated.reserveCapacity(lastIndexBySessionID.count)
    for (index, summary) in sessions.enumerated()
      where lastIndexBySessionID[summary.sessionId] == index
    {
      deduplicated.append(summary)
    }
    return deduplicated
  }

  nonisolated static func sortedSessionIDs(
    _ sessionIDs: [String],
    using sortOrder: SessionSortOrder,
    sessionRecordsByID: [String: SessionRecord]
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

  nonisolated static func sortRecentSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
    sessions.sorted { lhs, rhs in
      if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
      }
      return lhs.sessionId < rhs.sessionId
    }
  }

  nonisolated static func buildProjectCatalogs(
    projects: [ProjectSummary],
    sessions: [SessionSummary],
    sessionRecordsByID: [String: SessionRecord]
  ) -> [ProjectCatalog] {
    var checkoutsByProject: [String: [String: CheckoutAccumulator]] = [:]

    for summary in sessions {
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

    return projects.map { project in
      let checkouts = (checkoutsByProject[project.projectId] ?? [:]).values
        .map { checkout in
          CheckoutCatalog(
            checkoutId: checkout.checkoutId,
            title: checkout.title,
            isWorktree: checkout.isWorktree,
            recentActivitySessionIDs: sortedSessionIDs(
              checkout.sessionIDs,
              using: .recentActivity,
              sessionRecordsByID: sessionRecordsByID
            ),
            nameSessionIDs: sortedSessionIDs(
              checkout.sessionIDs,
              using: .name,
              sessionRecordsByID: sessionRecordsByID
            ),
            statusSessionIDs: sortedSessionIDs(
              checkout.sessionIDs,
              using: .status,
              sessionRecordsByID: sessionRecordsByID
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

  nonisolated static func orderedSessionIDsBySortOrder(
    from projectCatalogs: [ProjectCatalog]
  ) -> [SessionSortOrder: [String]] {
    Dictionary(
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
}
