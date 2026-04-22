import Foundation

extension HarnessMonitorStore {
  public struct CheckoutGroup: Identifiable, Equatable, Sendable {
    public let checkoutId: String
    public let title: String
    public let isWorktree: Bool
    public let sessionIDs: [String]

    public var id: String { checkoutId }
    public var sessionCount: Int { sessionIDs.count }
  }

  public struct SessionGroup: Identifiable, Equatable, Sendable {
    public let project: ProjectSummary
    public let checkoutGroups: [CheckoutGroup]

    public var sessionIDs: [String] {
      checkoutGroups.flatMap(\.sessionIDs)
    }

    public var id: String { project.id }
  }

  public enum StatusMessageTone: Equatable, Sendable {
    case secondary
    case info
    case success
    case caution
  }

  public struct SessionSummaryPresentation: Equatable, Sendable {
    public struct SidebarStatPresentation: Equatable, Sendable {
      public let symbolName: String
      public let valueText: String
      public let helpText: String

      public init(
        symbolName: String,
        valueText: String,
        helpText: String
      ) {
        self.symbolName = symbolName
        self.valueText = valueText
        self.helpText = helpText
      }
    }

    public let statusText: String
    public let statusTone: StatusMessageTone
    public let isEstimated: Bool
    public let agentStat: SidebarStatPresentation
    public let taskStat: SidebarStatPresentation
    public let accessibilityStatusText: String

    public init(
      statusText: String,
      statusTone: StatusMessageTone,
      isEstimated: Bool,
      agentStat: SidebarStatPresentation,
      taskStat: SidebarStatPresentation,
      accessibilityStatusText: String
    ) {
      self.statusText = statusText
      self.statusTone = statusTone
      self.isEstimated = isEstimated
      self.agentStat = agentStat
      self.taskStat = taskStat
      self.accessibilityStatusText = accessibilityStatusText
    }
  }

  public struct AgentActivityPresentation: Equatable, Sendable {
    public let label: String
    public let accessibilityValue: String

    public init(label: String, accessibilityValue: String) {
      self.label = label
      self.accessibilityValue = accessibilityValue
    }
  }

  public struct StatusMessageState: Equatable, Identifiable {
    public let id: String
    public let text: String
    public let systemImage: String?
    public let tone: StatusMessageTone

    public init(
      id: String,
      text: String,
      systemImage: String? = nil,
      tone: StatusMessageTone = .secondary
    ) {
      self.id = id
      self.text = text
      self.systemImage = systemImage
      self.tone = tone
    }
  }

  public struct ToolbarMetricsState: Equatable {
    public var projectCount = 0
    public var worktreeCount = 0
    public var sessionCount = 0
    public var openWorkCount = 0
    public var blockedCount = 0

    public init(
      projectCount: Int = 0,
      worktreeCount: Int = 0,
      sessionCount: Int = 0,
      openWorkCount: Int = 0,
      blockedCount: Int = 0
    ) {
      self.projectCount = projectCount
      self.worktreeCount = worktreeCount
      self.sessionCount = sessionCount
      self.openWorkCount = openWorkCount
      self.blockedCount = blockedCount
    }
  }

  public enum SidebarEmptyState: Equatable, Sendable {
    case noSessions
    case noMatches
    case sessionsAvailable
  }

  public struct InspectorTaskSelectionState: Equatable, Sendable {
    public let task: WorkItem
    public let notesSessionID: String?
    public let isPersistenceAvailable: Bool

    public init(
      task: WorkItem,
      notesSessionID: String?,
      isPersistenceAvailable: Bool
    ) {
      self.task = task
      self.notesSessionID = notesSessionID
      self.isPersistenceAvailable = isPersistenceAvailable
    }
  }

  public struct InspectorAgentSelectionState: Equatable, Sendable {
    public let agent: AgentRegistration
    public let activity: AgentToolActivitySummary?

    public init(
      agent: AgentRegistration,
      activity: AgentToolActivitySummary?
    ) {
      self.agent = agent
      self.activity = activity
    }
  }

  public struct SessionProjectionState: Equatable, Sendable {
    public var groupedSessions: [SessionGroup] = []
    public var filteredSessionCount = 0
    public var totalSessionCount = 0
    public var emptyState: SidebarEmptyState = .noSessions

    public init(
      groupedSessions: [SessionGroup] = [],
      filteredSessionCount: Int = 0,
      totalSessionCount: Int = 0,
      emptyState: SidebarEmptyState = .noSessions
    ) {
      self.groupedSessions = groupedSessions
      self.filteredSessionCount = filteredSessionCount
      self.totalSessionCount = totalSessionCount
      self.emptyState = emptyState
    }
  }

  public struct SessionSearchPresentationState: Equatable, Sendable {
    public var isSearchActive = false
    public var emptyState: SidebarEmptyState = .noSessions

    public init(
      isSearchActive: Bool = false,
      emptyState: SidebarEmptyState = .noSessions
    ) {
      self.isSearchActive = isSearchActive
      self.emptyState = emptyState
    }
  }

  public struct SessionSearchResultsListState: Equatable, Sendable {
    public var visibleSessionIDs: [String] = []

    public init(
      visibleSessionIDs: [String] = []
    ) {
      self.visibleSessionIDs = visibleSessionIDs
    }
  }

  public struct SessionSearchResultsState: Equatable, Sendable {
    public var presentation = SessionSearchPresentationState()
    public var filteredSessionCount = 0
    public var totalSessionCount = 0
    public var list = SessionSearchResultsListState()

    public init(
      presentation: SessionSearchPresentationState = SessionSearchPresentationState(),
      filteredSessionCount: Int = 0,
      totalSessionCount: Int = 0,
      list: SessionSearchResultsListState = SessionSearchResultsListState()
    ) {
      self.presentation = presentation
      self.filteredSessionCount = filteredSessionCount
      self.totalSessionCount = totalSessionCount
      self.list = list
    }
  }
}

extension HarnessMonitorStore {
  public func sessionSummaryPresentation(
    for summary: SessionSummary
  ) -> SessionSummaryPresentation {
    let isEstimated = sessionCatalogIsEstimated
    let isMalformedActiveLeaderless =
      summary.status == .active
      && summary.leaderId == nil
    let isLeaderless =
      summary.status == .leaderlessDegraded
      || isMalformedActiveLeaderless
    let usesKnownAgentPhrasing =
      summary.status == .awaitingLeader
      || isLeaderless

    let statusText =
      if summary.status == .awaitingLeader {
        "Awaiting Leader"
      } else if isLeaderless {
        "Leaderless"
      } else {
        summary.status.title
      }
    let statusTone: StatusMessageTone
    if isEstimated {
      statusTone = .secondary
    } else if summary.status == .awaitingLeader {
      statusTone = .info
    } else if isLeaderless {
      statusTone = .caution
    } else {
      switch summary.status {
      case .awaitingLeader:
        statusTone = .info
      case .active:
        statusTone = .success
      case .leaderlessDegraded:
        statusTone = .caution
      case .paused:
        statusTone = .caution
      case .ended:
        statusTone = .secondary
      }
    }

    let usesLiveAgentPhrasing =
      !isEstimated
      && !usesKnownAgentPhrasing
      && summary.status == .active
    let agentStat: SessionSummaryPresentation.SidebarStatPresentation
    if usesLiveAgentPhrasing {
      let agentCount = summary.metrics.activeAgentCount
      agentStat = SessionSummaryPresentation.SidebarStatPresentation(
        symbolName: "person.2.fill",
        valueText: "\(agentCount)",
        helpText: "\(agentCount) active"
      )
    } else {
      let agentCount = summary.metrics.agentCount
      agentStat = SessionSummaryPresentation.SidebarStatPresentation(
        symbolName: "person.2",
        valueText: "\(agentCount)",
        helpText: "\(agentCount) known"
      )
    }
    let movingTaskCount = summary.metrics.inProgressTaskCount
    let taskStat = SessionSummaryPresentation.SidebarStatPresentation(
      symbolName: "arrow.triangle.2.circlepath",
      valueText: "\(movingTaskCount)",
      helpText: "\(movingTaskCount) moving"
    )

    return SessionSummaryPresentation(
      statusText: statusText,
      statusTone: statusTone,
      isEstimated: isEstimated,
      agentStat: agentStat,
      taskStat: taskStat,
      accessibilityStatusText: isEstimated ? "\(statusText), estimated" : statusText
    )
  }

  public func agentActivityPresentation(
    for agent: AgentRegistration,
    queuedTasks: [WorkItem],
    isSelectedSessionLive: Bool
  ) -> AgentActivityPresentation {
    switch agent.status {
    case .disconnected:
      return AgentActivityPresentation(
        label: "Disconnected",
        accessibilityValue: "Disconnected"
      )
    case .removed:
      return AgentActivityPresentation(
        label: "Removed",
        accessibilityValue: "Removed"
      )
    case .active:
      guard isSelectedSessionLive else {
        return AgentActivityPresentation(
          label: "Snapshot",
          accessibilityValue: "Estimated activity"
        )
      }
      if !queuedTasks.isEmpty {
        let suffix = queuedTasks.count == 1 ? "task" : "tasks"
        return AgentActivityPresentation(
          label: "\(queuedTasks.count) queued \(suffix)",
          accessibilityValue: "\(queuedTasks.count) queued"
        )
      }
      let label = agent.currentTaskId == nil ? "Ready" : "Working"
      return AgentActivityPresentation(label: label, accessibilityValue: label)
    }
  }
}
