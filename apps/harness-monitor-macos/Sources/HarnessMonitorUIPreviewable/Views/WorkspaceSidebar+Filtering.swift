import HarnessMonitorKit

extension WorkspaceSidebar {
  var normalizedWorkspaceSearchQuery: String {
    workspaceSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  var filteredExternalAgents: [AgentRegistration] {
    externalAgents.filter { agent in
      matchesWorkspaceSearch([
        agent.name,
        agent.agentId,
        agent.role.title,
        runtimeDisplayLabel(agent.runtime),
        agent.currentTaskId,
      ])
    }
  }

  var filteredActiveTuis: [AgentTuiSnapshot] {
    activeTuis.filter { tui in
      matchesWorkspaceSearch([
        sessionTitlesByID[tui.tuiId],
        tui.tuiId,
        tui.runtime,
        tui.status.title,
      ])
    }
  }

  var filteredInactiveTuis: [AgentTuiSnapshot] {
    inactiveTuis.filter { tui in
      matchesWorkspaceSearch([
        sessionTitlesByID[tui.tuiId],
        tui.tuiId,
        tui.runtime,
        tui.status.title,
      ])
    }
  }

  var filteredActiveCodexRuns: [CodexRunSnapshot] {
    activeCodexRuns.filter { run in
      matchesWorkspaceSearch([
        codexTitlesByID[run.runId],
        run.runId,
        run.status.title,
        run.mode.title,
      ])
    }
  }

  var filteredInactiveCodexRuns: [CodexRunSnapshot] {
    inactiveCodexRuns.filter { run in
      matchesWorkspaceSearch([
        codexTitlesByID[run.runId],
        run.runId,
        run.status.title,
        run.mode.title,
      ])
    }
  }

  var filteredTasks: [WorkItem] {
    tasks.filter { task in
      matchesWorkspaceSearch([
        task.title,
        task.taskId,
        task.severity.title,
        task.status.title,
        task.assignedTo,
      ])
    }
  }

  var createRowMatchesWorkspaceSearch: Bool {
    matchesWorkspaceSearch(["Create", "New agent", "New terminal", "Codex run"])
  }

  func matchesWorkspaceSearch(_ values: [String?]) -> Bool {
    let query = normalizedWorkspaceSearchQuery
    guard !query.isEmpty else {
      return true
    }
    return values.contains { value in
      guard let value else { return false }
      return value.localizedCaseInsensitiveContains(query)
    }
  }
}
