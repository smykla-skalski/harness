import Foundation

public struct OpenAnythingSettingsSectionProjection: Hashable, Sendable {
  public let rawValue: String
  public let title: String
  public let systemImage: String

  public init(rawValue: String, title: String, systemImage: String) {
    self.rawValue = rawValue
    self.title = title
    self.systemImage = systemImage
  }
}

public struct OpenAnythingLoadedSessionSnapshot: Sendable {
  public let sessionID: String
  public let agents: [AgentRegistration]
  public let tasks: [WorkItem]
  public let timeline: [TimelineEntry]

  public init(
    sessionID: String,
    agents: [AgentRegistration],
    tasks: [WorkItem],
    timeline: [TimelineEntry]
  ) {
    self.sessionID = sessionID
    self.agents = agents
    self.tasks = tasks
    self.timeline = timeline
  }
}

public struct OpenAnythingCorpusInput: Sendable {
  public let settingsSections: [OpenAnythingSettingsSectionProjection]
  public let sessions: [SessionSummary]
  public let taskBoardItems: [TaskBoardItem]
  public let decisions: [DecisionPresentationSnapshot]
  public let dependencies: [DependencyUpdateItem]
  public let loadedSession: OpenAnythingLoadedSessionSnapshot?
  public let showsPolicyCanvasLab: Bool

  public init(
    settingsSections: [OpenAnythingSettingsSectionProjection],
    sessions: [SessionSummary],
    taskBoardItems: [TaskBoardItem],
    decisions: [DecisionPresentationSnapshot],
    dependencies: [DependencyUpdateItem],
    loadedSession: OpenAnythingLoadedSessionSnapshot?,
    showsPolicyCanvasLab: Bool
  ) {
    self.settingsSections = settingsSections
    self.sessions = sessions
    self.taskBoardItems = taskBoardItems
    self.decisions = decisions
    self.dependencies = dependencies
    self.loadedSession = loadedSession
    self.showsPolicyCanvasLab = showsPolicyCanvasLab
  }
}

public enum OpenAnythingCorpusBuilder {
  public static func records(input: OpenAnythingCorpusInput) -> [OpenAnythingRecord] {
    actionRecords(showsPolicyCanvasLab: input.showsPolicyCanvasLab)
      + windowRecords(showsPolicyCanvasLab: input.showsPolicyCanvasLab)
      + settingsRecords(input.settingsSections)
      + dashboardRouteRecords()
      + sessionRecords(input.sessions)
      + taskBoardRecords(input.taskBoardItems)
      + decisionRecords(input.decisions)
      + dependencyRecords(input.dependencies)
      + loadedSessionRecords(input.loadedSession)
  }

  private static func actionRecords(showsPolicyCanvasLab: Bool) -> [OpenAnythingRecord] {
    var actions: [OpenAnythingAction] = [
      .newSession,
      .newTask,
      .attachExternalSession,
      .refresh,
      .settings,
    ]
    if showsPolicyCanvasLab {
      actions.append(.policyCanvasLab)
    }
    return actions.map { action in
      OpenAnythingRecord(
        id: "action.\(action.rawValue)",
        domain: .actions,
        target: .action(action),
        title: actionTitle(action),
        subtitle: actionSubtitle(action),
        systemImage: actionSystemImage(action),
        searchBodyParts: [action.rawValue]
      )
    }
  }

  private static func windowRecords(showsPolicyCanvasLab: Bool) -> [OpenAnythingRecord] {
    var windows: [OpenAnythingWindowTarget] = [.dashboard, .settings]
    if showsPolicyCanvasLab {
      windows.append(.policyCanvasLab)
    }
    return windows.map { window in
      OpenAnythingRecord(
        id: "window.\(window.rawValue)",
        domain: .windows,
        target: .window(window),
        title: windowTitle(window),
        subtitle: "Window",
        systemImage: windowSystemImage(window),
        searchBodyParts: [window.rawValue]
      )
    }
  }

  private static func settingsRecords(
    _ sections: [OpenAnythingSettingsSectionProjection]
  ) -> [OpenAnythingRecord] {
    sections.map { section in
      OpenAnythingRecord(
        id: "settings.\(section.rawValue)",
        domain: .settings,
        target: .settingsSection(rawValue: section.rawValue),
        title: section.title,
        subtitle: "Settings",
        systemImage: section.systemImage,
        searchBodyParts: [section.rawValue]
      )
    }
  }

  private static func dashboardRouteRecords() -> [OpenAnythingRecord] {
    OpenAnythingDashboardRoute.allCases.map { route in
      OpenAnythingRecord(
        id: "dashboard.\(route.rawValue)",
        domain: .windows,
        target: .dashboardRoute(route),
        title: route.title,
        subtitle: "Dashboard",
        systemImage: route.systemImage,
        searchBodyParts: [route.rawValue]
      )
    }
  }

  private static func sessionRecords(_ sessions: [SessionSummary]) -> [OpenAnythingRecord] {
    sessions.map { session in
      OpenAnythingRecord(
        id: "session.\(session.sessionId)",
        domain: .sessions,
        target: .session(sessionID: session.sessionId),
        title: session.displayTitle,
        subtitle: session.projectName.isEmpty ? session.contextRoot : session.projectName,
        trailing: session.status.rawValue,
        systemImage: "rectangle.stack",
        searchBodyParts: [
          session.sessionId,
          session.branchRef,
          session.context,
          session.worktreePath,
          session.checkoutRoot,
        ]
      )
    }
  }

  private static func taskBoardRecords(_ items: [TaskBoardItem]) -> [OpenAnythingRecord] {
    items.map { item in
      OpenAnythingRecord(
        id: "taskBoard.\(item.id)",
        domain: .taskBoard,
        target: .taskBoardItem(
          id: item.id,
          sessionID: item.sessionId,
          workItemID: item.workItemId
        ),
        title: item.title,
        subtitle: item.status.rawValue,
        trailing: item.priority.rawValue,
        searchBodyParts: [item.id, item.body, item.tags.joined(separator: " ")]
      )
    }
  }

  private static func decisionRecords(
    _ decisions: [DecisionPresentationSnapshot]
  ) -> [OpenAnythingRecord] {
    decisions.map { decision in
      OpenAnythingRecord(
        id: "decision.\(decision.id)",
        domain: .decisions,
        target: .decision(id: decision.id, sessionID: decision.sessionID),
        title: decision.summary,
        subtitle: decision.ruleID,
        trailing: decision.severityRaw,
        searchBodyParts: [decision.id, decision.agentID, decision.taskID]
      )
    }
  }

  private static func dependencyRecords(_ items: [DependencyUpdateItem]) -> [OpenAnythingRecord] {
    items.map { item in
      OpenAnythingRecord(
        id: "dependency.\(item.pullRequestID)",
        domain: .dependencies,
        target: .dependency(pullRequestID: item.pullRequestID),
        title: item.title,
        subtitle: "\(item.repository)#\(item.number)",
        trailing: item.checkStatus.rawValue,
        searchBodyParts: [item.pullRequestID, item.authorLogin, item.labels.joined(separator: " ")]
      )
    }
  }

  private static func loadedSessionRecords(
    _ snapshot: OpenAnythingLoadedSessionSnapshot?
  ) -> [OpenAnythingRecord] {
    guard let snapshot else { return [] }
    return loadedAgentRecords(snapshot)
      + loadedTaskRecords(snapshot)
      + loadedTimelineRecords(snapshot)
  }

  private static func loadedAgentRecords(
    _ snapshot: OpenAnythingLoadedSessionSnapshot
  ) -> [OpenAnythingRecord] {
    snapshot.agents.map { agent in
      OpenAnythingRecord(
        id: "loadedSession.agent.\(snapshot.sessionID).\(agent.agentId)",
        domain: .loadedSession,
        target: .loadedSession(
          .agent(sessionID: snapshot.sessionID, agentID: agent.agentId)
        ),
        title: agent.name,
        subtitle: "Agent",
        trailing: agent.runtime,
        systemImage: "person.2",
        searchBodyParts: [
          agent.agentId,
          agent.persona?.name,
          agent.persona?.description,
          agent.role.rawValue,
        ]
      )
    }
  }

  private static func loadedTaskRecords(
    _ snapshot: OpenAnythingLoadedSessionSnapshot
  ) -> [OpenAnythingRecord] {
    snapshot.tasks.map { task in
      OpenAnythingRecord(
        id: "loadedSession.task.\(snapshot.sessionID).\(task.taskId)",
        domain: .loadedSession,
        target: .loadedSession(.task(sessionID: snapshot.sessionID, taskID: task.taskId)),
        title: task.title,
        subtitle: "Task",
        trailing: task.status.rawValue,
        systemImage: "checklist",
        searchBodyParts: [
          task.taskId,
          task.context,
          task.suggestedFix,
          task.blockedReason,
        ]
      )
    }
  }

  private static func loadedTimelineRecords(
    _ snapshot: OpenAnythingLoadedSessionSnapshot
  ) -> [OpenAnythingRecord] {
    snapshot.timeline.prefix(200).map { entry in
      OpenAnythingRecord(
        id: "loadedSession.timeline.\(snapshot.sessionID).\(entry.entryId)",
        domain: .loadedSession,
        target: .loadedSession(
          .timeline(sessionID: snapshot.sessionID, entryID: entry.entryId)
        ),
        title: entry.summary.isEmpty ? entry.kind : entry.summary,
        subtitle: "Timeline",
        trailing: entry.kind,
        systemImage: "clock.arrow.circlepath",
        searchBodyParts: [entry.entryId, entry.agentId, entry.taskId]
      )
    }
  }

  private static func actionTitle(_ action: OpenAnythingAction) -> String {
    switch action {
    case .newSession: "New Session"
    case .newTask: "New Task"
    case .attachExternalSession: "Attach External Session"
    case .refresh: "Refresh"
    case .settings: "Settings"
    case .policyCanvasLab: "Policy Canvas Lab"
    }
  }

  private static func actionSubtitle(_ action: OpenAnythingAction) -> String {
    switch action {
    case .newSession, .newTask, .attachExternalSession:
      "Create"
    case .refresh:
      "Reload Monitor data"
    case .settings:
      "Open Settings"
    case .policyCanvasLab:
      "Open experimental window"
    }
  }

  private static func actionSystemImage(_ action: OpenAnythingAction) -> String {
    switch action {
    case .newSession: "plus.rectangle.on.folder"
    case .newTask: "checklist"
    case .attachExternalSession: "link.badge.plus"
    case .refresh: "arrow.clockwise"
    case .settings: "gearshape"
    case .policyCanvasLab: "point.3.connected.trianglepath.dotted"
    }
  }

  private static func windowTitle(_ window: OpenAnythingWindowTarget) -> String {
    switch window {
    case .dashboard: "Dashboard"
    case .settings: "Settings"
    case .policyCanvasLab: "Policy Canvas Lab"
    }
  }

  private static func windowSystemImage(_ window: OpenAnythingWindowTarget) -> String {
    switch window {
    case .dashboard: "square.grid.2x2"
    case .settings: "gearshape"
    case .policyCanvasLab: "point.3.connected.trianglepath.dotted"
    }
  }
}
