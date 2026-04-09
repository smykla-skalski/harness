import Foundation
import Observation

public enum SessionSortOrder: String, CaseIterable, Identifiable {
  case recentActivity
  case name
  case status

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .recentActivity: "Recent Activity"
    case .name: "Name"
    case .status: "Status"
    }
  }

  func compare(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
    switch self {
    case .recentActivity:
      lhs.updatedAt > rhs.updatedAt
    case .name:
      lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
    case .status:
      lhs.status.sortKey < rhs.status.sortKey
    }
  }
}

private extension SessionStatus {
  var sortKey: Int {
    switch self {
    case .active: 0
    case .paused: 1
    case .ended: 2
    }
  }
}

public enum SessionFocusFilter: String, CaseIterable, Identifiable {
  case all
  case openWork
  case blocked
  case observed
  case idle

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .all:
      "All"
    case .openWork:
      "Open Work"
    case .blocked:
      "Blocked"
    case .observed:
      "Observed"
    case .idle:
      "Idle"
    }
  }

  func includes(_ summary: SessionSummary) -> Bool {
    switch self {
    case .all:
      true
    case .openWork:
      summary.metrics.openTaskCount > 0 || summary.metrics.inProgressTaskCount > 0
    case .blocked:
      summary.metrics.blockedTaskCount > 0
    case .observed:
      summary.observeId != nil
    case .idle:
      summary.metrics.activeAgentCount == 0 && summary.metrics.openTaskCount == 0
    }
  }
}

extension HarnessMonitorStore {
  @MainActor
  @Observable
  public final class SessionIndexSlice {
    public enum Change {
      case data
      case projection
    }

    private enum SummaryChangeImpact {
      case catalog
      case projection
      case summaryOnly
    }

    private struct SessionRecord {
      let summary: SessionSummary
      let normalizedSearchCorpus: String
      let normalizedName: String

      init(summary: SessionSummary) {
        self.summary = summary
        normalizedSearchCorpus = SessionIndexSlice.normalizedSearchCorpus(for: summary)
        normalizedName = summary.displayTitle.sessionSearchNormalized
      }

      var statusSortKey: Int { summary.status.sortKey }
      var recentActivitySortKey: String { summary.updatedAt }
    }

    private struct CheckoutCatalog {
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

    private struct CheckoutAccumulator {
      let checkoutId: String
      let title: String
      let isWorktree: Bool
      var sessionIDs: [String]
    }

    private struct ProjectCatalog {
      let project: ProjectSummary
      let checkouts: [CheckoutCatalog]
    }

    @ObservationIgnored public var onChanged: ((Change) -> Void)?
    public let catalog: SessionCatalogSlice
    public let controls: SessionControlsSlice
    public let projection: SessionProjectionSlice

    @ObservationIgnored private var suppressRefresh = false
    @ObservationIgnored private var sessionSummariesByID: [String: SessionSummary] = [:]
    @ObservationIgnored private var sessionRecordsByID: [String: SessionRecord] = [:]
    @ObservationIgnored private var sessionIndicesByID: [String: Int] = [:]
    @ObservationIgnored private var projectCatalogs: [ProjectCatalog] = []
    @ObservationIgnored private var queryTokens: [String] = []
    @ObservationIgnored private(set) var debugCatalogRebuildCount = 0
    @ObservationIgnored private(set) var debugProjectionRebuildCount = 0

    public var projects: [ProjectSummary] {
      get { catalog.projects }
      set { refreshCatalogIfNeeded(newValue != catalog.projects, projects: newValue, sessions: catalog.sessions) }
    }

    public var sessions: [SessionSummary] {
      get { catalog.sessions }
      set { refreshCatalogIfNeeded(newValue != catalog.sessions, projects: catalog.projects, sessions: newValue) }
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
      projection.groupedSessions
    }

    public var filteredSessionCount: Int {
      projection.filteredSessionCount
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
      projection.visibleSessionIDs
    }

    public var recentSessions: [SessionSummary] {
      catalog.recentSessions
    }

    public init() {
      self.catalog = SessionCatalogSlice()
      self.controls = SessionControlsSlice()
      self.projection = SessionProjectionSlice()
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
          rebuildCatalogAndProjection()
        case .projection:
          patchCatalog(existingSummary: existing, updatedSummary: summary)
          rebuildProjection(change: .data)
        case .summaryOnly:
          patchCatalog(existingSummary: existing, updatedSummary: summary)
          patchVisibleProjection(summary)
          onChanged?(.data)
        }
        return true
      }

      var updated = catalog.sessions
      updated.append(summary)
      suppressRefresh = true
      catalog.sessions = updated
      suppressRefresh = false
      rebuildCatalogAndProjection()
      return true
    }

    public func sessionSummary(for sessionID: String?) -> SessionSummary? {
      guard let sessionID else {
        return nil
      }
      return sessionSummariesByID[sessionID]
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
      refreshProjectionIfNeeded(didChangeQuery)
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
      rebuildProjection(change: .projection)
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
      sessionSummariesByID = Dictionary(
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
      sessionSummariesByID[updatedSummary.sessionId] = updatedSummary
      sessionRecordsByID[updatedSummary.sessionId] = SessionRecord(summary: updatedSummary)
      catalog.totalOpenWorkCount += updatedSummary.metrics.openTaskCount
        - existingSummary.metrics.openTaskCount
      catalog.totalBlockedCount += updatedSummary.metrics.blockedTaskCount
        - existingSummary.metrics.blockedTaskCount
      if existingSummary.updatedAt != updatedSummary.updatedAt {
        catalog.recentSessions = sortRecentSessions(catalog.sessions)
      } else {
        catalog.recentSessions = replacingSession(updatedSummary, in: catalog.recentSessions)
      }
    }

    private func patchVisibleProjection(_ updatedSummary: SessionSummary) {
      let currentState = projection.state
      guard currentState.visibleSessionIDs.contains(updatedSummary.sessionId) else {
        return
      }

      let updatedGroups = currentState.groupedSessions.map { group in
        guard group.project.projectId == updatedSummary.projectId else {
          return group
        }

        let updatedCheckoutGroups = group.checkoutGroups.map { checkout in
          guard checkout.checkoutId == updatedSummary.checkoutId else {
            return checkout
          }

          let updatedSessions = replacingSession(updatedSummary, in: checkout.sessions)
          guard updatedSessions != checkout.sessions else {
            return checkout
          }

          return HarnessMonitorStore.CheckoutGroup(
            checkoutId: checkout.checkoutId,
            title: checkout.title,
            isWorktree: checkout.isWorktree,
            sessions: updatedSessions
          )
        }

        guard updatedCheckoutGroups != group.checkoutGroups else {
          return group
        }

        return SessionGroup(
          project: group.project,
          checkoutGroups: updatedCheckoutGroups
        )
      }

      guard updatedGroups != currentState.groupedSessions else {
        return
      }

      var nextState = currentState
      nextState.groupedSessions = updatedGroups
      projection.state = nextState
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
      debugProjectionRebuildCount += 1
      queryTokens = Self.normalizedQueryTokens(for: controls.searchText)

      let visibleRecords = catalog.sessions.compactMap { summary -> SessionRecord? in
        guard let record = sessionRecordsByID[summary.sessionId], matchesCurrentFilters(record) else {
          return nil
        }
        return record
      }

      let visibleSessionIDs = visibleRecords.map(\.summary.sessionId)
      let visibleRecordsByID = Dictionary(uniqueKeysWithValues: visibleRecords.map {
        ($0.summary.sessionId, $0)
      })

      let groupedSessions = projectCatalogs.compactMap { projectCatalog -> SessionGroup? in
        let checkoutGroups = projectCatalog.checkouts.compactMap { checkout -> HarnessMonitorStore
          .CheckoutGroup? in
          let checkoutSessions = checkout
            .orderedSessionIDs(for: controls.sessionSortOrder)
            .compactMap { visibleRecordsByID[$0]?.summary }
          guard !checkoutSessions.isEmpty else {
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
      let emptyState: SidebarEmptyState
      if catalog.totalSessionCount == 0 {
        emptyState = .noSessions
      } else if groupedSessions.isEmpty {
        emptyState = .noMatches
      } else {
        emptyState = .sessionsAvailable
      }

      let nextState = SessionProjectionState(
        searchText: controls.searchText,
        sessionFilter: controls.sessionFilter,
        sessionFocusFilter: controls.sessionFocusFilter,
        sessionSortOrder: controls.sessionSortOrder,
        groupedSessions: groupedSessions,
        filteredSessionCount: visibleSessionIDs.count,
        totalSessionCount: catalog.totalSessionCount,
        visibleSessionIDs: visibleSessionIDs,
        emptyState: emptyState
      )

      if projection.state != nextState {
        projection.state = nextState
      }

      onChanged?(change)
    }

    private func sortedSessionIDs(
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

    private func sortRecentSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
      sessions.sorted { lhs, rhs in
        if lhs.updatedAt != rhs.updatedAt {
          return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.sessionId < rhs.sessionId
      }
    }

    private func replacingSession(
      _ updatedSummary: SessionSummary,
      in sessions: [SessionSummary]
    ) -> [SessionSummary] {
      sessions.map { session in
        session.sessionId == updatedSummary.sessionId ? updatedSummary : session
      }
    }

    private func matchesCurrentFilters(_ record: SessionRecord) -> Bool {
      controls.sessionFilter.includes(record.summary.status)
        && controls.sessionFocusFilter.includes(record.summary)
        && searchMatches(record)
    }

    private func searchMatches(_ record: SessionRecord) -> Bool {
      guard !queryTokens.isEmpty else {
        return true
      }
      return queryTokens.allSatisfy(record.normalizedSearchCorpus.contains)
    }

    private func requiresCatalogRebuild(
      from existing: SessionSummary,
      to updated: SessionSummary
    ) -> Bool {
      existing.projectId != updated.projectId
        || existing.checkoutId != updated.checkoutId
        || existing.isWorktree != updated.isWorktree
        || existing.worktreeName != updated.worktreeName
        || existing.checkoutRoot != updated.checkoutRoot
    }

    private func summaryChangeImpact(
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

    nonisolated private static func normalizedSearchCorpus(for summary: SessionSummary) -> String {
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

    nonisolated private static func normalizedQueryTokens(for rawValue: String) -> [String] {
      rawValue.sessionSearchTokens
    }
  }
}

extension HarnessMonitorStore {
  public var projects: [ProjectSummary] {
    get { sessionIndex.projects }
    set { sessionIndex.projects = newValue }
  }

  public var sessions: [SessionSummary] {
    get { sessionIndex.sessions }
    set { sessionIndex.sessions = newValue }
  }

  public var searchText: String {
    get { sessionIndex.searchText }
    set { sessionIndex.searchText = newValue }
  }

  public var sessionFilter: SessionFilter {
    get { sessionIndex.sessionFilter }
    set { sessionIndex.sessionFilter = newValue }
  }

  public var sessionFocusFilter: SessionFocusFilter {
    get { sessionIndex.sessionFocusFilter }
    set { sessionIndex.sessionFocusFilter = newValue }
  }

  public var sessionSortOrder: SessionSortOrder {
    get { sessionIndex.sessionSortOrder }
    set { sessionIndex.sessionSortOrder = newValue }
  }

  public var groupedSessions: [SessionGroup] {
    sessionIndex.groupedSessions
  }

  public var filteredSessionCount: Int {
    sessionIndex.filteredSessionCount
  }

  public var totalSessionCount: Int {
    sessionIndex.totalSessionCount
  }

  public var visibleSessionIDs: [String] {
    sessionIndex.visibleSessionIDs
  }

  public var recentSessions: [SessionSummary] {
    sessionIndex.recentSessions
  }

  public var totalOpenWorkCount: Int {
    sessionIndex.totalOpenWorkCount
  }

  public var totalBlockedCount: Int {
    sessionIndex.totalBlockedCount
  }

  public var selectedSessionSummary: SessionSummary? {
    sessionIndex.sessionSummary(for: selectedSessionID)
  }

  public var availableActionActors: [AgentRegistration] {
    let agents = selectedSession?.agents ?? []
    return agents.filter { $0.status == .active }
  }

  public var selectedTask: WorkItem? {
    guard case .task(let taskID) = inspectorSelection else {
      return nil
    }
    return selectedSession?.tasks.first(where: { $0.taskId == taskID })
  }

  public var selectedAgent: AgentRegistration? {
    guard case .agent(let agentID) = inspectorSelection else {
      return nil
    }
    return selectedSession?.agents.first(where: { $0.agentId == agentID })
  }

  public var selectedSignal: SessionSignalRecord? {
    guard case .signal(let signalID) = inspectorSelection else {
      return nil
    }
    return selectedSession?.signals.first(where: { $0.signal.signalId == signalID })
  }

  public func resetFilters() {
    searchText = ""
    sessionFilter = .active
    sessionFocusFilter = .all
  }
}

private extension String {
  var sessionSearchNormalized: String {
    folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  var sessionSearchTokens: [String] {
    sessionSearchNormalized
      .split(separator: " ")
      .map(String.init)
  }
}
