import Foundation
import Observation

extension HarnessMonitorStore {
  @MainActor
  @Observable
  public final class SessionIndexSlice {
    public enum Change {
      case data
      case projection
    }

    @ObservationIgnored public var onChanged: ((Change) -> Void)?
    public let catalog: SessionCatalogSlice
    public let controls: SessionControlsSlice
    public let projection: SessionProjectionSlice
    public let searchResults: SessionSearchResultsSlice

    @ObservationIgnored private var suppressRefresh = false
    @ObservationIgnored var sessionRecordsByID: [String: SessionRecord] = [:]
    @ObservationIgnored private var sessionIndicesByID: [String: Int] = [:]
    @ObservationIgnored var projectCatalogs: [ProjectCatalog] = []
    @ObservationIgnored var queryTokens: [String] = []
    @ObservationIgnored private var searchRebuildTask: Task<Void, Never>?
    @ObservationIgnored private(set) var debugCatalogRebuildCount = 0
    @ObservationIgnored private(set) var debugProjectionRebuildCount = 0

    private static let searchRebuildDebounceNanoseconds: UInt64 = 150_000_000

    public var projects: [ProjectSummary] {
      get { catalog.projects }
      set {
        refreshCatalogIfNeeded(
          newValue != catalog.projects, projects: newValue, sessions: catalog.sessions)
      }
    }

    public var sessions: [SessionSummary] {
      get { catalog.sessions }
      set {
        refreshCatalogIfNeeded(
          newValue != catalog.sessions, projects: catalog.projects, sessions: newValue)
      }
    }

    public var searchText: String {
      get { controls.searchText }
      set { updateSearchText(newValue) }
    }

    public var sessionFilter: SessionFilter {
      get { controls.sessionFilter }
      set { updateSessionFilter(newValue) }
    }

    public var sessionFocusFilter: SessionFocusFilter {
      get { controls.sessionFocusFilter }
      set { updateSessionFocusFilter(newValue) }
    }

    public var sessionSortOrder: SessionSortOrder {
      get { controls.sessionSortOrder }
      set { updateSessionSortOrder(newValue) }
    }

    public var groupedSessions: [SessionGroup] {
      guard queryTokens.isEmpty else {
        return buildGroupedSessions(
          visibleSessionIDSet: Set(searchResults.visibleSessionIDs)
        )
      }
      return projection.groupedSessions
    }

    public var filteredSessionCount: Int {
      searchResults.filteredSessionCount
    }

    public var totalSessionCount: Int {
      catalog.totalSessionCount
    }

    public var totalOpenWorkCount: Int {
      catalog.totalOpenWorkCount
    }

    public var totalBlockedCount: Int {
      catalog.totalBlockedCount
    }

    public var visibleSessionIDs: [String] {
      searchResults.visibleSessionIDs
    }

    public var recentSessions: [SessionSummary] {
      catalog.recentSessions
    }

    public init() {
      self.catalog = SessionCatalogSlice()
      self.controls = SessionControlsSlice()
      self.projection = SessionProjectionSlice()
      self.searchResults = SessionSearchResultsSlice()
      rebuildProjection(change: .projection)
    }

    @discardableResult
    public func replaceSnapshot(
      projects: [ProjectSummary],
      sessions: [SessionSummary]
    ) -> Bool {
      guard catalog.projects != projects || catalog.sessions != sessions else {
        return false
      }

      cancelPendingSearchRebuild()
      suppressRefresh = true
      catalog.projects = projects
      catalog.sessions = sessions
      suppressRefresh = false
      rebuildCatalogAndProjection()
      return true
    }

    @discardableResult
    public func applySessionSummary(_ summary: SessionSummary) -> Bool {
      if let index = sessionIndicesByID[summary.sessionId] {
        let existing = catalog.sessions[index]
        guard existing != summary else {
          return false
        }

        var updated = catalog.sessions
        updated[index] = summary
        suppressRefresh = true
        catalog.sessions = updated
        suppressRefresh = false

        switch summaryChangeImpact(from: existing, to: summary) {
        case .catalog:
          cancelPendingSearchRebuild()
          rebuildCatalogAndProjection()
        case .projection:
          cancelPendingSearchRebuild()
          patchCatalog(existingSummary: existing, updatedSummary: summary)
          rebuildProjection(change: .data)
        case .summaryOnly:
          patchCatalog(existingSummary: existing, updatedSummary: summary)
          onChanged?(.data)
        }
        return true
      }

      var updated = catalog.sessions
      updated.append(summary)
      suppressRefresh = true
      catalog.sessions = updated
      suppressRefresh = false
      cancelPendingSearchRebuild()
      rebuildCatalogAndProjection()
      return true
    }

    public func flushPendingSearchRebuild() {
      guard searchRebuildTask != nil else {
        return
      }
      cancelPendingSearchRebuild()
      rebuildProjection(change: .projection)
    }

    public func sessionSummary(for sessionID: String?) -> SessionSummary? {
      guard let sessionID else {
        return nil
      }
      return catalog.sessionSummary(for: sessionID)
    }

    private func refreshCatalogIfNeeded(
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
      rebuildCatalogAndProjection()
    }

    private func updateSearchText(_ newValue: String) {
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

    private func updateSessionFilter(_ newValue: SessionFilter) {
      guard controls.sessionFilter != newValue else {
        return
      }
      controls.sessionFilter = newValue
      refreshProjectionIfNeeded(true)
    }

    private func updateSessionFocusFilter(_ newValue: SessionFocusFilter) {
      guard controls.sessionFocusFilter != newValue else {
        return
      }
      controls.sessionFocusFilter = newValue
      refreshProjectionIfNeeded(true)
    }

    private func updateSessionSortOrder(_ newValue: SessionSortOrder) {
      guard controls.sessionSortOrder != newValue else {
        return
      }
      controls.sessionSortOrder = newValue
      refreshProjectionIfNeeded(true)
    }

    private func refreshProjectionIfNeeded(_ changed: Bool) {
      guard changed, !suppressRefresh else {
        return
      }
      cancelPendingSearchRebuild()
      rebuildProjection(change: .projection)
    }

    private func scheduleSearchRebuild(for targetSearchText: String) {
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

    private func cancelPendingSearchRebuild() {
      searchRebuildTask?.cancel()
      searchRebuildTask = nil
    }

    private func rebuildCatalogAndProjection() {
      rebuildCatalog()
      rebuildProjection(change: .data)
    }

    private func rebuildCatalog() {
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
      catalog.recentSessions = sortRecentSessions(catalog.sessions)
    }

    private func patchCatalog(
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
    }

    private func buildProjectCatalogs() -> [ProjectCatalog] {
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

    private func rebuildProjection(change: Change) {
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
      let visibleSessions = orderedVisibleSessionIDs.compactMap { sessionRecordsByID[$0]?.summary }
      let emptyState: SidebarEmptyState
      if catalog.totalSessionCount == 0 {
        emptyState = .noSessions
      } else if orderedVisibleSessionIDs.isEmpty {
        emptyState = .noMatches
      } else {
        emptyState = .sessionsAvailable
      }

      if queryTokens.isEmpty {
        projection.apply(
          SessionProjectionState(
            groupedSessions: buildGroupedSessions(visibleSessionIDSet: visibleSessionIDSet),
            filteredSessionCount: orderedVisibleSessionIDs.count,
            totalSessionCount: catalog.totalSessionCount,
            emptyState: emptyState
          )
        )
      }
      let nextSearchResults = SessionSearchResultsState(
        filteredSessionCount: orderedVisibleSessionIDs.count,
        totalSessionCount: catalog.totalSessionCount,
        visibleSessionIDs: orderedVisibleSessionIDs,
        visibleSessions: visibleSessions,
        emptyState: emptyState
      )
      if searchResults.state != nextSearchResults {
        searchResults.state = nextSearchResults
      }

      onChanged?(change)
    }

    private func buildGroupedSessions(
      visibleSessionIDSet: Set<String>
    ) -> [SessionGroup] {
      projectCatalogs.compactMap { projectCatalog -> SessionGroup? in
        let checkoutGroups =
          projectCatalog.checkouts.compactMap { checkout -> HarnessMonitorStore.CheckoutGroup? in
            let checkoutSessionIDs =
              checkout
              .orderedSessionIDs(for: controls.sessionSortOrder)
              .filter { visibleSessionIDSet.contains($0) }
            let checkoutSessions = checkoutSessionIDs.compactMap { sessionRecordsByID[$0]?.summary }
            guard !checkoutSessionIDs.isEmpty else {
              return nil
            }
            return HarnessMonitorStore.CheckoutGroup(
              checkoutId: checkout.checkoutId,
              title: checkout.title,
              isWorktree: checkout.isWorktree,
              sessions: checkoutSessions
            )
          }
        guard !checkoutGroups.isEmpty else {
          return nil
        }
        return SessionGroup(project: projectCatalog.project, checkoutGroups: checkoutGroups)
      }
    }

  }
}
