import Foundation

extension HarnessMonitorStore {
  public struct CheckoutGroup: Identifiable, Equatable {
    public let checkoutId: String
    public let title: String
    public let isWorktree: Bool
    public let sessions: [SessionSummary]

    public var id: String { checkoutId }
    public var sessionIDs: [String] { sessions.map(\.sessionId) }
    public var sessionCount: Int { sessions.count }
  }

  public struct SessionGroup: Identifiable, Equatable {
    public let project: ProjectSummary
    public let checkoutGroups: [CheckoutGroup]

    public var sessionIDs: [String] {
      checkoutGroups.flatMap(\.sessionIDs)
    }

    public var id: String { project.id }
  }

  public enum StatusMessageTone: Equatable {
    case secondary
    case info
    case success
    case caution
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

  public enum DaemonIndicatorState: Equatable {
    case offline
    case launchdConnected
    case manualConnected
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

  public enum SidebarEmptyState: Equatable {
    case noSessions
    case noMatches
    case sessionsAvailable
  }

  public struct InspectorTaskSelectionState: Equatable {
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

  public struct InspectorAgentSelectionState: Equatable {
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

  public enum InspectorPrimaryContentState: Equatable {
    case empty
    case loading(SessionSummary)
    case session(SessionDetail)
    case task(InspectorTaskSelectionState)
    case agent(InspectorAgentSelectionState)
    case signal(SessionSignalRecord)
    case observer(ObserverSummary)

    public var identity: String {
      switch self {
      case .empty:
        return "empty"
      case .loading(let summary):
        return "loading:\(summary.sessionId)"
      case .session(let detail):
        return "session:\(detail.session.sessionId)"
      case .task(let selection):
        return "task:\(selection.task.taskId)"
      case .agent(let selection):
        return "agent:\(selection.agent.agentId)"
      case .signal(let signal):
        return "signal:\(signal.signal.signalId)"
      case .observer(let observer):
        return "observer:\(observer.observeId)"
      }
    }

    public var observer: ObserverSummary? {
      guard case .observer(let observer) = self else {
        return nil
      }
      return observer
    }

    public init(
      selectedSession: SessionDetail?,
      selectedSessionSummary: SessionSummary?,
      inspectorSelection: HarnessMonitorStore.InspectorSelection,
      isPersistenceAvailable: Bool
    ) {
      guard let selectedSession else {
        if let selectedSessionSummary {
          self = .loading(selectedSessionSummary)
        } else {
          self = .empty
        }
        return
      }

      self = Self.resolveSelection(
        selectedSession: selectedSession,
        inspectorSelection: inspectorSelection,
        isPersistenceAvailable: isPersistenceAvailable
      )
    }

    private static func resolveSelection(
      selectedSession: SessionDetail,
      inspectorSelection: HarnessMonitorStore.InspectorSelection,
      isPersistenceAvailable: Bool
    ) -> Self {
      switch inspectorSelection {
      case .none:
        return .session(selectedSession)
      case .task(let taskID):
        guard let task = selectedSession.tasks.first(where: { $0.taskId == taskID }) else {
          return .session(selectedSession)
        }
        return .task(
          InspectorTaskSelectionState(
            task: task,
            notesSessionID: selectedSession.session.sessionId,
            isPersistenceAvailable: isPersistenceAvailable
          )
        )
      case .agent(let agentID):
        guard let agent = selectedSession.agents.first(where: { $0.agentId == agentID }) else {
          return .session(selectedSession)
        }
        return .agent(
          InspectorAgentSelectionState(
            agent: agent,
            activity: selectedSession.agentActivity.first(where: { $0.agentId == agent.agentId })
          )
        )
      case .signal(let signalID):
        guard
          let signal = selectedSession.signals.first(where: { $0.signal.signalId == signalID })
        else {
          return .session(selectedSession)
        }
        return .signal(signal)
      case .observer:
        if let observer = selectedSession.observer {
          return .observer(observer)
        }
        return .session(selectedSession)
      }
    }
  }

  public struct InspectorActionContext: Equatable {
    public let detail: SessionDetail
    public let selectedTask: WorkItem?
    public let selectedAgent: AgentRegistration?
    public let selectedObserver: ObserverSummary?
    public let isPersistenceAvailable: Bool
    public let actionActorOptions: [AgentRegistration]
    public let selectedActionActorID: String
    public let isSessionReadOnly: Bool
    public let isSessionActionInFlight: Bool
    public let lastAction: String
    public let lastError: String?

    public init(
      detail: SessionDetail,
      selectedTask: WorkItem?,
      selectedAgent: AgentRegistration?,
      selectedObserver: ObserverSummary?,
      isPersistenceAvailable: Bool,
      actionActorOptions: [AgentRegistration],
      selectedActionActorID: String,
      isSessionReadOnly: Bool,
      isSessionActionInFlight: Bool,
      lastAction: String,
      lastError: String?
    ) {
      self.detail = detail
      self.selectedTask = selectedTask
      self.selectedAgent = selectedAgent
      self.selectedObserver = selectedObserver
      self.isPersistenceAvailable = isPersistenceAvailable
      self.actionActorOptions = actionActorOptions
      self.selectedActionActorID = selectedActionActorID
      self.isSessionReadOnly = isSessionReadOnly
      self.isSessionActionInFlight = isSessionActionInFlight
      self.lastAction = lastAction
      self.lastError = lastError
    }

    public init?(
      detail: SessionDetail?,
      inspectorSelection: HarnessMonitorStore.InspectorSelection,
      isPersistenceAvailable: Bool,
      selectedActionActorID: String,
      isSessionReadOnly: Bool,
      isSessionActionInFlight: Bool,
      lastAction: String,
      lastError: String?
    ) {
      guard let detail else {
        return nil
      }

      let selectedTask: WorkItem?
      if case .task(let taskID) = inspectorSelection {
        selectedTask = detail.tasks.first(where: { $0.taskId == taskID })
      } else {
        selectedTask = nil
      }

      let selectedAgent: AgentRegistration?
      if case .agent(let agentID) = inspectorSelection {
        selectedAgent = detail.agents.first(where: { $0.agentId == agentID })
      } else {
        selectedAgent = nil
      }

      let selectedObserver: ObserverSummary?
      if case .observer = inspectorSelection {
        selectedObserver = detail.observer
      } else {
        selectedObserver = nil
      }

      self.init(
        detail: detail,
        selectedTask: selectedTask,
        selectedAgent: selectedAgent,
        selectedObserver: selectedObserver,
        isPersistenceAvailable: isPersistenceAvailable,
        actionActorOptions: Self.actionActorOptions(
          for: detail,
          selectedActionActorID: selectedActionActorID
        ),
        selectedActionActorID: selectedActionActorID,
        isSessionReadOnly: isSessionReadOnly,
        isSessionActionInFlight: isSessionActionInFlight,
        lastAction: lastAction,
        lastError: lastError
      )
    }

    private static func actionActorOptions(
      for detail: SessionDetail,
      selectedActionActorID: String
    ) -> [AgentRegistration] {
      var seenAgentIDs = Set<String>()
      var options: [AgentRegistration] = []

      func append(_ agent: AgentRegistration?) {
        guard let agent else {
          return
        }
        guard seenAgentIDs.insert(agent.agentId).inserted else {
          return
        }
        options.append(agent)
      }

      for agent in detail.agents where agent.status == .active {
        append(agent)
      }
      append(detail.agents.first { $0.agentId == selectedActionActorID })
      append(detail.agents.first { $0.agentId == detail.session.leaderId })
      return options
    }
  }

  public struct SessionProjectionState: Equatable {
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

  public struct SessionSearchResultsState: Equatable {
    public var isSearchActive = false
    public var filteredSessionCount = 0
    public var totalSessionCount = 0
    public var visibleSessionIDs: [String] = []
    public var visibleSessions: [SessionSummary] = []
    public var emptyState: SidebarEmptyState = .noSessions

    public init(
      isSearchActive: Bool = false,
      filteredSessionCount: Int = 0,
      totalSessionCount: Int = 0,
      visibleSessionIDs: [String] = [],
      visibleSessions: [SessionSummary] = [],
      emptyState: SidebarEmptyState = .noSessions
    ) {
      self.isSearchActive = isSearchActive
      self.filteredSessionCount = filteredSessionCount
      self.totalSessionCount = totalSessionCount
      self.visibleSessionIDs = visibleSessionIDs
      self.visibleSessions = visibleSessions
      self.emptyState = emptyState
    }
  }
}
