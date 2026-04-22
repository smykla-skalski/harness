import Foundation

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
    sessionSortOrder = .recentActivity
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
