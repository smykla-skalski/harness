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
  public let reviews: [ReviewItem]
  public let loadedSession: OpenAnythingLoadedSessionSnapshot?
  public let showsPolicyCanvasLab: Bool

  public init(
    settingsSections: [OpenAnythingSettingsSectionProjection],
    sessions: [SessionSummary],
    taskBoardItems: [TaskBoardItem],
    decisions: [DecisionPresentationSnapshot],
    reviews: [ReviewItem],
    loadedSession: OpenAnythingLoadedSessionSnapshot?,
    showsPolicyCanvasLab: Bool
  ) {
    self.settingsSections = settingsSections
    self.sessions = sessions
    self.taskBoardItems = taskBoardItems
    self.decisions = decisions
    self.reviews = reviews
    self.loadedSession = loadedSession
    self.showsPolicyCanvasLab = showsPolicyCanvasLab
  }
}

public enum OpenAnythingCorpusBuilder {
  /// Builds the unified record list consumed by ``OpenAnythingIndex``.
  ///
  /// Dashboard routes (`.openTaskBoard`, `.openReviews`, `.openNotifications`,
  /// `.openDiagnostics`, `.openPolicyCanvas`) ship exclusively as action
  /// records - the prior `dashboardRouteRecords()` helper produced duplicate
  /// entries that resolved to the same routing step.
  public static func records(input: OpenAnythingCorpusInput) -> [OpenAnythingRecord] {
    actionRecords(showsPolicyCanvasLab: input.showsPolicyCanvasLab)
      + windowRecords(showsPolicyCanvasLab: input.showsPolicyCanvasLab)
      + settingsRecords(input.settingsSections)
      + sessionRecords(input.sessions)
      + taskBoardRecords(input.taskBoardItems)
      + decisionRecords(input.decisions)
      + reviewRecords(input.reviews)
      + loadedSessionRecords(input.loadedSession)
  }

  private static func actionRecords(showsPolicyCanvasLab: Bool) -> [OpenAnythingRecord] {
    var actions: [OpenAnythingAction] = [
      .newSession,
      .newTask,
      .attachExternalSession,
      .openDashboard,
      .openTaskBoard,
      .openReviews,
      .openNotifications,
      .openDiagnostics,
      .refresh,
      .refreshDiagnostics,
      .reconnectDaemon,
      .copyDiagnostics,
      .settings,
      .openMCPSettings,
      .openDatabaseSettings,
    ]
    if showsPolicyCanvasLab {
      actions.append(.openPolicyCanvas)
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
        isSuggested: suggestedActions.contains(action),
        searchBodyParts: [action.rawValue, actionSearchAliases(action)]
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
        title: window.title,
        subtitle: "Window",
        systemImage: window.systemImage,
        isSuggested: window == .dashboard,
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

  private static func sessionRecords(_ sessions: [SessionSummary]) -> [OpenAnythingRecord] {
    sessions.map { session in
      OpenAnythingRecord(
        id: "session.\(session.sessionId)",
        domain: .sessions,
        target: .session(sessionID: session.sessionId),
        title: session.displayTitle,
        subtitle: sessionSubtitle(session),
        trailing: displayLabel(session.status.rawValue),
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
        subtitle: displayLabel(item.status.rawValue),
        trailing: displayLabel(item.priority.rawValue),
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
        trailing: displayLabel(decision.severityRaw),
        searchBodyParts: [decision.id, decision.agentID, decision.taskID]
      )
    }
  }

  private static func reviewRecords(_ items: [ReviewItem]) -> [OpenAnythingRecord] {
    items.map { item in
      OpenAnythingRecord(
        id: "review.\(item.pullRequestID)",
        domain: .reviews,
        target: .review(pullRequestID: item.pullRequestID),
        title: item.title,
        subtitle: reviewSubtitle(item),
        trailing: displayLabel(item.checkStatus.rawValue),
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

  /// Loaded-session entries (Agent/Task/Timeline) are only emitted when a
  /// session is currently loaded in the dashboard (i.e. when the corpus host
  /// passes a non-nil snapshot). This is intentional: these entries reference
  /// the active session's identifiers, so surfacing them without a loaded
  /// session would route to dead targets.
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
        trailing: displayLabel(task.status.rawValue),
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

  /// `HarnessMonitorStore.timeline` is sorted newest-first (see
  /// `HarnessMonitorStore+AcpTimeline.timelineEntrySortOrder`), so `prefix(200)`
  /// surfaces the most recent 200 entries. If the store's ordering contract
  /// ever changes, switch to `suffix(200)` to preserve the recency bias.
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

  private static func sessionSubtitle(_ session: SessionSummary) -> String {
    let projectComponent =
      session.projectName.isEmpty ? session.contextRoot : session.projectName
    let branchRef = session.branchRef.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !branchRef.isEmpty else {
      return projectComponent
    }
    if projectComponent.isEmpty {
      return branchRef
    }
    return "\(projectComponent) · \(branchRef)"
  }

  private static func reviewSubtitle(_ item: ReviewItem) -> String {
    let trimmedLogin = item.authorLogin.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = "\(item.repository)#\(item.number)"
    guard !trimmedLogin.isEmpty else {
      return base
    }
    return "\(base) · @\(trimmedLogin)"
  }

  /// Converts a snake_case raw value (`"in_progress"`, `"needs_user"`, `"p0"`)
  /// into a Title Case display label (`"In Progress"`, `"Needs User"`, `"P0"`).
  /// Used inline so that touching enums like ``TaskBoardStatus`` or
  /// ``DecisionSeverity`` is not required.
  static func displayLabel(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return trimmed }
    return
      trimmed
      .split(separator: "_", omittingEmptySubsequences: true)
      .map { component -> String in
        guard let first = component.first else { return "" }
        return first.uppercased() + component.dropFirst()
      }
      .joined(separator: " ")
  }
}
