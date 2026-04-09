import Foundation
import Observation
import SwiftData

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
    public let availableActionActors: [AgentRegistration]
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
      availableActionActors: [AgentRegistration],
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
      self.availableActionActors = availableActionActors
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
        availableActionActors: detail.agents.filter { $0.status == .active },
        selectedActionActorID: selectedActionActorID,
        isSessionReadOnly: isSessionReadOnly,
        isSessionActionInFlight: isSessionActionInFlight,
        lastAction: lastAction,
        lastError: lastError
      )
    }
  }

  @MainActor
  @Observable
  public final class ConnectionSlice {
    public enum Change {
      case shellState
      case metrics
    }

    @ObservationIgnored public var onChanged: ((Change) -> Void)?
    public var connectionState: ConnectionState = .idle {
      didSet { onChanged?(.shellState) }
    }
    public var daemonStatus: DaemonStatusReport? {
      didSet { onChanged?(.shellState) }
    }
    public var diagnostics: DaemonDiagnosticsReport?
    public var health: HealthResponse?
    public var isRefreshing = false {
      didSet { onChanged?(.shellState) }
    }
    public var isDiagnosticsRefreshInFlight = false
    public var isDaemonActionInFlight = false {
      didSet { onChanged?(.shellState) }
    }
    public var activeTransport: TransportKind = .httpSSE
    public var connectionMetrics: ConnectionMetrics = .initial {
      didSet { onChanged?(.metrics) }
    }
    public var connectionEvents: [ConnectionEvent] = []
    public var subscribedSessionIDs: Set<String> = []
    public var daemonLogLevel: String?
    public var isShowingCachedData = false {
      didSet { onChanged?(.shellState) }
    }
    public var persistedSessionCount = 0 {
      didSet { onChanged?(.shellState) }
    }
    public var lastPersistedSnapshotAt: Date? {
      didSet { onChanged?(.shellState) }
    }
  }

  @MainActor
  @Observable
  public final class SelectionSlice {
    public enum Change {
      case selectedSessionID
      case selectedSession
      case timeline
      case inspectorSelection
      case actionActorID
      case selectionLoading
      case extensionsLoading
      case sessionAction
    }

    @ObservationIgnored public var onChanged: ((Change) -> Void)?
    public var selectedSessionID: String? {
      didSet { onChanged?(.selectedSessionID) }
    }
    public var selectedSession: SessionDetail? {
      didSet { onChanged?(.selectedSession) }
    }
    public var timeline: [TimelineEntry] = [] {
      didSet { onChanged?(.timeline) }
    }
    public var inspectorSelection: InspectorSelection = .none {
      didSet { onChanged?(.inspectorSelection) }
    }
    public var actionActorID: String? {
      didSet { onChanged?(.actionActorID) }
    }
    public var isSelectionLoading = false {
      didSet { onChanged?(.selectionLoading) }
    }
    public var isExtensionsLoading = false {
      didSet { onChanged?(.extensionsLoading) }
    }
    public var isSessionActionInFlight = false {
      didSet { onChanged?(.sessionAction) }
    }

    public var matchedSelectedSession: SessionDetail? {
      guard let selectedSessionID,
        let selectedSession,
        selectedSession.session.sessionId == selectedSessionID
      else {
        return nil
      }
      return selectedSession
    }
  }

  @MainActor
  @Observable
  public final class UserDataSlice {
    @ObservationIgnored public var onChanged: (() -> Void)?
    public var bookmarkedSessionIds: Set<String> = [] {
      didSet { onChanged?() }
    }

    public init() {}
  }

  @MainActor
  @Observable
  public final class SessionCatalogSlice {
    public internal(set) var projects: [ProjectSummary] = []
    public internal(set) var sessions: [SessionSummary] = []
    public internal(set) var sessionSummariesByID: [String: SessionSummary] = [:]
    public internal(set) var totalSessionCount = 0
    public internal(set) var totalOpenWorkCount = 0
    public internal(set) var totalBlockedCount = 0
    public internal(set) var recentSessions: [SessionSummary] = []

    public init() {}

    public func sessionSummary(for sessionID: String) -> SessionSummary? {
      sessionSummariesByID[sessionID]
    }
  }

  @MainActor
  @Observable
  public final class SessionControlsSlice {
    public var searchText = ""
    public var sessionFilter: SessionFilter = .all
    public var sessionFocusFilter: SessionFocusFilter = .all
    public var sessionSortOrder: SessionSortOrder = .recentActivity

    public init() {}
  }

  public struct SessionProjectionState: Equatable {
    public var groupedSessions: [SessionGroup] = []
    public var filteredSessionCount = 0
    public var totalSessionCount = 0
    public var visibleSessionIDs: [String] = []
    public var visibleSessions: [SessionSummary] = []
    public var emptyState: SidebarEmptyState = .noSessions

    public init(
      groupedSessions: [SessionGroup] = [],
      filteredSessionCount: Int = 0,
      totalSessionCount: Int = 0,
      visibleSessionIDs: [String] = [],
      visibleSessions: [SessionSummary] = [],
      emptyState: SidebarEmptyState = .noSessions
    ) {
      self.groupedSessions = groupedSessions
      self.filteredSessionCount = filteredSessionCount
      self.totalSessionCount = totalSessionCount
      self.visibleSessionIDs = visibleSessionIDs
      self.visibleSessions = visibleSessions
      self.emptyState = emptyState
    }
  }

  @MainActor
  @Observable
  public final class SessionProjectionSlice {
    public internal(set) var state = SessionProjectionState()

    public var groupedSessions: [SessionGroup] { state.groupedSessions }
    public var filteredSessionCount: Int { state.filteredSessionCount }
    public var totalSessionCount: Int { state.totalSessionCount }
    public var visibleSessionIDs: [String] { state.visibleSessionIDs }
    public var visibleSessions: [SessionSummary] { state.visibleSessions }
    public var emptyState: SidebarEmptyState { state.emptyState }

    public init() {}
  }

  @MainActor
  public final class ContentUISlice {
    public let shell = ContentShellSlice()
    public let toolbar = ContentToolbarSlice()
    public let chrome = ContentChromeSlice()
    public let session = ContentSessionSlice()
    public let dashboard = ContentDashboardSlice()

    public init() {}
  }

  @MainActor
  @Observable
  public final class ContentShellSlice {
    public var selectedSessionID: String?
    public var windowTitle = "Dashboard"
    public var connectionState: ConnectionState = .idle
    public var isRefreshing = false
    public var isSelectionLoading = false
    public var isExtensionsLoading = false
    public var lastAction = ""
    public var pendingConfirmation: PendingConfirmation?
    public var presentedSheet: PresentedSheet?

    public init() {}
  }

  @MainActor
  @Observable
  public final class ContentToolbarSlice {
    public var toolbarMetrics = HarnessMonitorStore.ToolbarMetricsState()
    public var statusMessages: [HarnessMonitorStore.StatusMessageState] = []
    public var daemonIndicator: HarnessMonitorStore.DaemonIndicatorState = .offline
    public var canNavigateBack = false
    public var canNavigateForward = false
    public var isRefreshing = false
    public var sleepPreventionEnabled = false
    public var connectionState: ConnectionState = .idle
    public var isBusy = false

    public init() {}
  }

  @MainActor
  @Observable
  public final class ContentChromeSlice {
    public var persistenceError: String?
    public var sessionDataAvailability: SessionDataAvailability = .live
    public var sessionStatus: SessionStatus?

    public init() {}
  }

  @MainActor
  @Observable
  public final class ContentSessionSlice {
    public var selectedSessionSummary: SessionSummary?
    public var isSessionReadOnly = true
    public var isSessionActionInFlight = false
    public var isSelectionLoading = false
    public var isExtensionsLoading = false
    public var lastAction = ""

    public init() {}
  }

  @MainActor
  @Observable
  public final class ContentDashboardSlice {
    public var connectionState: ConnectionState = .idle
    public var isBusy = false
    public var isRefreshing = false
    public var isLaunchAgentInstalled = false

    public init() {}
  }

  @MainActor
  @Observable
  public final class SidebarUISlice {
    public var connectionMetrics: ConnectionMetrics = .initial
    public var selectedSessionID: String?
    public var isPersistenceAvailable = false
    public var bookmarkedSessionIds: Set<String> = []
  }

  @MainActor
  @Observable
  public final class InspectorUISlice {
    public var isPersistenceAvailable = false
    public var selectedActionActorID = ""
    public var isSessionReadOnly = true
    public var isSessionActionInFlight = false
    public var lastAction = ""
    public var lastError: String?
    public var primaryContent: InspectorPrimaryContentState = .empty
    public var actionContext: InspectorActionContext?
  }
}
