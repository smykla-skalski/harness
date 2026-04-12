import Foundation

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

extension SessionStatus {
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

extension HarnessMonitorStore.SessionIndexSlice {
  enum SummaryChangeImpact {
    case catalog
    case projection
    case summaryOnly
  }

  struct SessionRecord {
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

  struct CheckoutCatalog {
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

  struct CheckoutAccumulator {
    let checkoutId: String
    let title: String
    let isWorktree: Bool
    var sessionIDs: [String]
  }

  struct ProjectCatalog {
    let project: ProjectSummary
    let checkouts: [CheckoutCatalog]
  }

  func orderedVisibleSessionIDs(in visibleSessionIDSet: Set<String>) -> [String] {
    orderedSessionIDsBySortOrder[controls.sessionSortOrder, default: []]
      .filter { visibleSessionIDSet.contains($0) }
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

extension HarnessMonitorStore {
  public var indexedProjectCount: Int {
    sessionIndex.indexedProjectCount
  }

  public var indexedWorktreeCount: Int {
    sessionIndex.indexedWorktreeCount
  }

  public var indexedSessionCount: Int {
    sessionIndex.indexedSessionCount
  }

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

  public func flushPendingSearchRebuild() {
    sessionIndex.flushPendingSearchRebuild()
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

  public var visibleSessions: [SessionSummary] {
    visibleSessionIDs.compactMap { sessionIndex.sessionSummary(for: $0) }
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
    sessionFilter = .all
    sessionFocusFilter = .all
    flushPendingSearchRebuild()
  }
}

extension HarnessMonitorStore.SessionIndexSlice {
  var indexedProjectCount: Int {
    projectCatalogs.lazy.filter { !$0.checkouts.isEmpty }.count
  }

  var indexedWorktreeCount: Int {
    projectCatalogs.reduce(into: 0) { count, projectCatalog in
      count += projectCatalog.checkouts.reduce(into: 0) { checkoutCount, checkout in
        if checkout.isWorktree, !checkout.recentActivitySessionIDs.isEmpty {
          checkoutCount += 1
        }
      }
    }
  }

  var indexedSessionCount: Int {
    sessions.count
  }
}

extension String {
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
