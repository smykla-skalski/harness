import Foundation

extension MonitorStore {
  public var groupedSessions: [SessionGroup] {
    let filteredSessions = sessions.filter { summary in
      sessionFilter.includes(summary.status) && searchMatches(summary)
    }
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

  private func searchMatches(_ summary: SessionSummary) -> Bool {
    let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else {
      return true
    }

    let haystack = [
      summary.projectName,
      summary.sessionId,
      summary.context,
      summary.leaderId ?? "",
    ].joined(separator: " ").lowercased()

    return haystack.contains(needle.lowercased())
  }
}
