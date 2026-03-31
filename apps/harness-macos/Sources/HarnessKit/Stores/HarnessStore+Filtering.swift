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
      lhs.context.localizedStandardCompare(rhs.context) == .orderedAscending
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

extension HarnessStore {
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
