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

extension HarnessMonitorStore {
  @MainActor
  @Observable
  public final class SessionIndexSlice {
    public var projects: [ProjectSummary] = [] {
      didSet { refreshDerivedStateIfNeeded(oldValue != projects) }
    }
    public var sessions: [SessionSummary] = [] {
      didSet { refreshDerivedStateIfNeeded(oldValue != sessions) }
    }
    public var searchText = "" {
      didSet { refreshDerivedStateIfNeeded(oldValue != searchText) }
    }
    public var sessionFilter: SessionFilter = .active {
      didSet { refreshDerivedStateIfNeeded(oldValue != sessionFilter) }
    }
    public var sessionFocusFilter: SessionFocusFilter = .all {
      didSet { refreshDerivedStateIfNeeded(oldValue != sessionFocusFilter) }
    }
    public var sessionSortOrder: SessionSortOrder = .recentActivity {
      didSet { refreshDerivedStateIfNeeded(oldValue != sessionSortOrder) }
    }
    public private(set) var groupedSessions: [SessionGroup] = []
    public private(set) var filteredSessionCount = 0
    public private(set) var totalOpenWorkCount = 0
    public private(set) var totalBlockedCount = 0
    public private(set) var sessionSummariesByID: [String: SessionSummary] = [:]

    private var suppressDerivedStateRefresh = false

    public init() {}

    public func replaceSnapshot(
      projects: [ProjectSummary],
      sessions: [SessionSummary]
    ) {
      guard self.projects != projects || self.sessions != sessions else {
        return
      }

      suppressDerivedStateRefresh = true
      self.projects = projects
      self.sessions = sessions
      suppressDerivedStateRefresh = false
      rebuildDerivedState()
    }

    public func applySessionSummary(_ summary: SessionSummary) {
      var updated = sessions
      if let index = updated.firstIndex(where: { $0.sessionId == summary.sessionId }) {
        guard updated[index] != summary else {
          return
        }
        updated[index] = summary
      } else {
        updated.append(summary)
      }
      sessions = updated
    }

    public func sessionSummary(for sessionID: String?) -> SessionSummary? {
      guard let sessionID else {
        return nil
      }
      return sessionSummariesByID[sessionID]
    }

    private func refreshDerivedStateIfNeeded(_ changed: Bool) {
      guard changed, !suppressDerivedStateRefresh else {
        return
      }
      rebuildDerivedState()
    }

    private func rebuildDerivedState() {
      totalOpenWorkCount = sessions.reduce(0) { $0 + $1.metrics.openTaskCount }
      totalBlockedCount = sessions.reduce(0) { $0 + $1.metrics.blockedTaskCount }
      sessionSummariesByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0) })

      let filteredSessions = sessions.filter(matchesCurrentFilters)
      filteredSessionCount = filteredSessions.count
      let sessionsByProject = Dictionary(grouping: filteredSessions, by: \.projectId)

      groupedSessions = projects.compactMap { project in
        guard let sessions = sessionsByProject[project.projectId], !sessions.isEmpty else {
          return nil
        }
        return SessionGroup(
          project: project,
          sessions: sessions.sorted(by: sessionSortOrder.compare)
        )
      }
    }

    private func matchesCurrentFilters(_ summary: SessionSummary) -> Bool {
      sessionFilter.includes(summary.status)
        && sessionFocusFilter.includes(summary)
        && searchMatches(summary)
    }

    private func searchMatches(_ summary: SessionSummary) -> Bool {
      let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !needle.isEmpty else {
        return true
      }

      let haystack = [
        summary.projectName,
        summary.projectId,
        summary.sessionId,
        summary.context,
        summary.projectDir ?? "",
        summary.contextRoot,
        summary.leaderId ?? "",
        summary.observeId ?? "",
        summary.status.rawValue,
      ].joined(separator: " ")

      return needle
        .split(whereSeparator: \.isWhitespace)
        .allSatisfy { haystack.localizedStandardContains($0) }
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
