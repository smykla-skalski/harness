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

public struct OpenAnythingLoadedSessionSnapshot: Equatable, Sendable {
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

  public init(
    settingsSections: [OpenAnythingSettingsSectionProjection],
    sessions: [SessionSummary],
    taskBoardItems: [TaskBoardItem],
    decisions: [DecisionPresentationSnapshot],
    reviews: [ReviewItem],
    loadedSession: OpenAnythingLoadedSessionSnapshot?
  ) {
    self.settingsSections = settingsSections
    self.sessions = sessions
    self.taskBoardItems = taskBoardItems
    self.decisions = decisions
    self.reviews = reviews
    self.loadedSession = loadedSession
  }
}

public enum OpenAnythingCorpusBuilder {
  /// Builds the unified record list consumed by ``OpenAnythingIndex``.
  ///
  /// Dashboard routes (`.openTaskBoard`, `.openReviews`, `.openAudit`,
  /// `.openDiagnostics`, `.openPolicyCanvas`) ship exclusively as action
  /// records - the prior `dashboardRouteRecords()` helper produced duplicate
  /// entries that resolved to the same routing step.
  public static func records(input: OpenAnythingCorpusInput) -> [OpenAnythingRecord] {
    guard !Task.isCancelled else { return [] }
    // Plugin records appear after the built-in records so a plugin cannot
    // accidentally hide a core action by emitting a higher-ranked title.
    // Today no production plugin is registered; the registry exists so a
    // future feature can fan records into the palette without touching the
    // corpus builder.
    let pluginRecords = OpenAnythingPluginRegistry.shared.records(input: input)
    let actions = actionTargets()
    let windows = windowTargets()
    var records: [OpenAnythingRecord] = []
    records.reserveCapacity(
      estimatedRecordCount(
        input: input,
        actionCount: actions.count,
        windowCount: windows.count,
        pluginRecordCount: pluginRecords.count
      )
    )
    appendActionRecords(actions, to: &records)
    appendWindowRecords(windows, to: &records)
    appendSettingsRecords(input.settingsSections, to: &records)
    guard !Task.isCancelled else { return records }
    appendSessionRecords(input.sessions, to: &records)
    guard !Task.isCancelled else { return records }
    appendTaskBoardRecords(input.taskBoardItems, to: &records)
    guard !Task.isCancelled else { return records }
    appendDecisionRecords(input.decisions, to: &records)
    guard !Task.isCancelled else { return records }
    appendReviewRecords(input.reviews, to: &records)
    guard !Task.isCancelled else { return records }
    appendLoadedSessionRecords(input.loadedSession, to: &records)
    guard !Task.isCancelled else { return records }
    records.append(contentsOf: pluginRecords)
    return records
  }

  private static func actionTargets() -> [OpenAnythingAction] {
    [
      .newSession,
      .newTask,
      .attachExternalSession,
      .openDashboard,
      .openTaskBoard,
      .openReviews,
      .openAudit,
      .openNotifications,
      .openDiagnostics,
      .openDebugging,
      .refresh,
      .refreshDiagnostics,
      .reconnectDaemon,
      .copyDiagnostics,
      .settings,
      .openMCPSettings,
      .openDatabaseSettings,
    ]
  }

  private static func appendActionRecords(
    _ actions: [OpenAnythingAction],
    to records: inout [OpenAnythingRecord]
  ) {
    for action in actions {
      records.append(
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
      )
    }
  }

  private static func windowTargets() -> [OpenAnythingWindowTarget] {
    [.dashboard, .settings]
  }

  private static func appendWindowRecords(
    _ windows: [OpenAnythingWindowTarget],
    to records: inout [OpenAnythingRecord]
  ) {
    for window in windows {
      records.append(
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
      )
    }
  }

  private static func appendSettingsRecords(
    _ sections: [OpenAnythingSettingsSectionProjection],
    to records: inout [OpenAnythingRecord]
  ) {
    for section in sections {
      records.append(
        OpenAnythingRecord(
          id: "settings.\(section.rawValue)",
          domain: .settings,
          target: .settingsSection(rawValue: section.rawValue),
          title: section.title,
          subtitle: "Settings",
          systemImage: section.systemImage,
          searchBodyParts: [section.rawValue]
        )
      )
    }
  }

  private static func appendSessionRecords(
    _ sessions: [SessionSummary],
    to records: inout [OpenAnythingRecord]
  ) {
    for session in sessions {
      guard !Task.isCancelled else { return }
      records.append(
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
      )
    }
  }

  private static func appendTaskBoardRecords(
    _ items: [TaskBoardItem],
    to records: inout [OpenAnythingRecord]
  ) {
    for item in items {
      guard !Task.isCancelled else { return }
      records.append(
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
          searchBodyParts: [item.id, item.body],
          searchBodyTokens: item.tags
        )
      )
    }
  }

  private static func appendDecisionRecords(
    _ decisions: [DecisionPresentationSnapshot],
    to records: inout [OpenAnythingRecord]
  ) {
    for decision in decisions {
      guard !Task.isCancelled else { return }
      records.append(
        OpenAnythingRecord(
          id: "decision.\(decision.id)",
          domain: .decisions,
          target: .decision(id: decision.id, sessionID: decision.sessionID),
          title: decision.summary,
          subtitle: decision.ruleID,
          trailing: displayLabel(decision.severityRaw),
          searchBodyParts: [decision.id, decision.agentID, decision.taskID]
        )
      )
    }
  }

  private static func appendReviewRecords(
    _ items: [ReviewItem],
    to records: inout [OpenAnythingRecord]
  ) {
    for item in items {
      guard !Task.isCancelled else { return }
      records.append(
        OpenAnythingRecord(
          id: "review.\(item.pullRequestID)",
          domain: .reviews,
          target: .review(pullRequestID: item.pullRequestID),
          title: item.title,
          subtitle: reviewSubtitle(item),
          trailing: displayLabel(item.checkStatus.rawValue),
          searchBodyParts: [item.pullRequestID, item.authorLogin],
          searchBodyTokens: item.labels
        )
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
    var label = ""
    label.reserveCapacity(trimmed.count)
    var insertsSeparator = false
    var capitalizesNext = true
    for character in trimmed {
      if character == "_" {
        insertsSeparator = !label.isEmpty
        capitalizesNext = true
        continue
      }
      if insertsSeparator {
        label.append(" ")
        insertsSeparator = false
      }
      if capitalizesNext {
        label.append(contentsOf: character.uppercased())
      } else {
        label.append(character)
      }
      capitalizesNext = false
    }
    return label
  }
}
