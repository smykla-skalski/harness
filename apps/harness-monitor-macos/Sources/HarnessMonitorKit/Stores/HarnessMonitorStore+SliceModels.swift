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

  public struct InspectorLookupIndex {
    public let detail: SessionDetail

    private let tasksByID: [String: WorkItem]
    private let agentsByID: [String: AgentRegistration]
    private let signalsByID: [String: SessionSignalRecord]
    private let agentActivityByID: [String: AgentToolActivitySummary]

    public init(detail: SessionDetail) {
      self.detail = detail
      tasksByID = Dictionary(uniqueKeysWithValues: detail.tasks.map { ($0.taskId, $0) })
      agentsByID = Dictionary(uniqueKeysWithValues: detail.agents.map { ($0.agentId, $0) })
      signalsByID = Dictionary(
        uniqueKeysWithValues: detail.signals.map { ($0.signal.signalId, $0) }
      )
      agentActivityByID = Dictionary(
        uniqueKeysWithValues: detail.agentActivity.map { ($0.agentId, $0) }
      )
    }

    public func task(for taskID: String) -> WorkItem? {
      tasksByID[taskID]
    }

    public func agent(for agentID: String) -> AgentRegistration? {
      agentsByID[agentID]
    }

    public func signal(for signalID: String) -> SessionSignalRecord? {
      signalsByID[signalID]
    }

    public func primaryContent(
      for inspectorSelection: HarnessMonitorStore.InspectorSelection,
      isPersistenceAvailable: Bool
    ) -> InspectorPrimaryContentState {
      switch inspectorSelection {
      case .none:
        return .session(detail)
      case .task(let taskID):
        guard let task = task(for: taskID) else {
          return .session(detail)
        }
        return .task(
          InspectorTaskSelectionState(
            task: task,
            notesSessionID: detail.session.sessionId,
            isPersistenceAvailable: isPersistenceAvailable
          )
        )
      case .agent(let agentID):
        guard let agent = agent(for: agentID) else {
          return .session(detail)
        }
        return .agent(
          InspectorAgentSelectionState(
            agent: agent,
            activity: agentActivityByID[agent.agentId]
          )
        )
      case .signal(let signalID):
        guard let signal = signal(for: signalID) else {
          return .session(detail)
        }
        return .signal(signal)
      case .observer:
        if let observer = detail.observer {
          return .observer(observer)
        }
        return .session(detail)
      }
    }

    public func actionContext(
      inspectorSelection: HarnessMonitorStore.InspectorSelection,
      isPersistenceAvailable: Bool,
      selectedActionActorID: String,
      isSessionReadOnly: Bool,
      isSessionActionInFlight: Bool
    ) -> InspectorActionContext? {
      let selectedTask: WorkItem?
      if case .task(let taskID) = inspectorSelection {
        selectedTask = task(for: taskID)
      } else {
        selectedTask = nil
      }

      let selectedAgent: AgentRegistration?
      if case .agent(let agentID) = inspectorSelection {
        selectedAgent = agent(for: agentID)
      } else {
        selectedAgent = nil
      }

      let selectedObserver: ObserverSummary?
      if case .observer = inspectorSelection {
        selectedObserver = detail.observer
      } else {
        selectedObserver = nil
      }

      return InspectorActionContext(
        detail: detail,
        selectedTask: selectedTask,
        selectedAgent: selectedAgent,
        selectedObserver: selectedObserver,
        isPersistenceAvailable: isPersistenceAvailable,
        actionActorOptions: actionActorOptions(selectedActionActorID: selectedActionActorID),
        selectedActionActorID: selectedActionActorID,
        isSessionReadOnly: isSessionReadOnly,
        isSessionActionInFlight: isSessionActionInFlight
      )
    }

    func actionActorOptions(
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
      append(agentsByID[selectedActionActorID])
      if let leaderID = detail.session.leaderId {
        append(agentsByID[leaderID])
      }
      return options
    }
  }

  public enum InspectorPrimaryContentState: Equatable, Sendable {
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

      self = InspectorLookupIndex(detail: selectedSession).primaryContent(
        for: inspectorSelection,
        isPersistenceAvailable: isPersistenceAvailable
      )
    }
  }

  public struct InspectorActionContext: Equatable, Sendable {
    public let detail: SessionDetail
    public let selectedTask: WorkItem?
    public let selectedAgent: AgentRegistration?
    public let selectedObserver: ObserverSummary?
    public let isPersistenceAvailable: Bool
    public let actionActorOptions: [AgentRegistration]
    public let selectedActionActorID: String
    public let isSessionReadOnly: Bool
    public let isSessionActionInFlight: Bool

    public init(
      detail: SessionDetail,
      selectedTask: WorkItem?,
      selectedAgent: AgentRegistration?,
      selectedObserver: ObserverSummary?,
      isPersistenceAvailable: Bool,
      actionActorOptions: [AgentRegistration],
      selectedActionActorID: String,
      isSessionReadOnly: Bool,
      isSessionActionInFlight: Bool
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
    }

    public init?(
      detail: SessionDetail?,
      inspectorSelection: HarnessMonitorStore.InspectorSelection,
      isPersistenceAvailable: Bool,
      selectedActionActorID: String,
      isSessionReadOnly: Bool,
      isSessionActionInFlight: Bool
    ) {
      guard let detail else {
        return nil
      }

      guard let actionContext = InspectorLookupIndex(detail: detail).actionContext(
        inspectorSelection: inspectorSelection,
        isPersistenceAvailable: isPersistenceAvailable,
        selectedActionActorID: selectedActionActorID,
        isSessionReadOnly: isSessionReadOnly,
        isSessionActionInFlight: isSessionActionInFlight
      ) else {
        return nil
      }
      self = actionContext
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
