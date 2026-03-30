import Foundation

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
  public var groupedSessions: [SessionGroup] {
    let filteredSessions = sessions.filter(matchesCurrentFilters)
    let sessionsByProject = Dictionary(grouping: filteredSessions, by: \.projectId)

    return projects.compactMap { project in
      guard let sessions = sessionsByProject[project.projectId], !sessions.isEmpty else {
        return nil
      }
      return SessionGroup(
        project: project,
        sessions: sessions.sorted { $0.updatedAt > $1.updatedAt }
      )
    }
  }

  public var filteredSessionCount: Int {
    sessions.filter(matchesCurrentFilters).count
  }

  public var totalOpenWorkCount: Int {
    sessions.reduce(0) { $0 + $1.metrics.openTaskCount }
  }

  public var totalBlockedCount: Int {
    sessions.reduce(0) { $0 + $1.metrics.blockedTaskCount }
  }

  public var selectedSessionSummary: SessionSummary? {
    guard let selectedSessionID else {
      return nil
    }

    return sessions.first(where: { $0.sessionId == selectedSessionID })
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
    ].joined(separator: " ").lowercased()

    return
      needle
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .allSatisfy { haystack.contains($0) }
  }
}
