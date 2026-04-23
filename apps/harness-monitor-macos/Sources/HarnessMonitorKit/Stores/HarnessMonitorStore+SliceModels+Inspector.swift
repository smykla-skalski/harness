import Foundation

extension HarnessMonitorStore {
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

      let selectedObserver: ObserverSummary?
      if case .observer = inspectorSelection {
        selectedObserver = detail.observer
      } else {
        selectedObserver = nil
      }

      return InspectorActionContext(
        detail: detail,
        selectedTask: selectedTask,
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
      isPersistenceAvailable: Bool,
      lookupIndex: HarnessMonitorStore.InspectorLookupIndex? = nil
    ) {
      guard let selectedSession else {
        if let selectedSessionSummary {
          self = .loading(selectedSessionSummary)
        } else {
          self = .empty
        }
        return
      }

      let index = lookupIndex ?? InspectorLookupIndex(detail: selectedSession)
      self = index.primaryContent(
        for: inspectorSelection,
        isPersistenceAvailable: isPersistenceAvailable
      )
    }
  }

  public struct InspectorActionContext: Equatable, Sendable {
    public let detail: SessionDetail
    public let selectedTask: WorkItem?
    public let selectedObserver: ObserverSummary?
    public let isPersistenceAvailable: Bool
    public let actionActorOptions: [AgentRegistration]
    public let selectedActionActorID: String
    public let isSessionReadOnly: Bool
    public let isSessionActionInFlight: Bool

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.detail.session.sessionId == rhs.detail.session.sessionId
        && lhs.detail.session.updatedAt == rhs.detail.session.updatedAt
        && lhs.selectedTask == rhs.selectedTask
        && lhs.selectedObserver == rhs.selectedObserver
        && lhs.isPersistenceAvailable == rhs.isPersistenceAvailable
        && lhs.actionActorOptions.map(\.agentId) == rhs.actionActorOptions.map(\.agentId)
        && lhs.actionActorOptions.map(\.status) == rhs.actionActorOptions.map(\.status)
        && lhs.selectedActionActorID == rhs.selectedActionActorID
        && lhs.isSessionReadOnly == rhs.isSessionReadOnly
        && lhs.isSessionActionInFlight == rhs.isSessionActionInFlight
    }

    public init(
      detail: SessionDetail,
      selectedTask: WorkItem?,
      selectedObserver: ObserverSummary?,
      isPersistenceAvailable: Bool,
      actionActorOptions: [AgentRegistration],
      selectedActionActorID: String,
      isSessionReadOnly: Bool,
      isSessionActionInFlight: Bool
    ) {
      self.detail = detail
      self.selectedTask = selectedTask
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
      isSessionActionInFlight: Bool,
      lookupIndex: HarnessMonitorStore.InspectorLookupIndex? = nil
    ) {
      guard let detail else {
        return nil
      }

      let index = lookupIndex ?? InspectorLookupIndex(detail: detail)
      guard
        let actionContext = index.actionContext(
          inspectorSelection: inspectorSelection,
          isPersistenceAvailable: isPersistenceAvailable,
          selectedActionActorID: selectedActionActorID,
          isSessionReadOnly: isSessionReadOnly,
          isSessionActionInFlight: isSessionActionInFlight
        )
      else {
        return nil
      }
      self = actionContext
    }
  }
}
