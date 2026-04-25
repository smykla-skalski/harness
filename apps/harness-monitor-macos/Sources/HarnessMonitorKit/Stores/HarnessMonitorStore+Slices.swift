import Foundation
import Observation
import SwiftData

extension HarnessMonitorStore {
  @MainActor
  @Observable
  public final class ConnectionSlice {
    public enum Change {
      case connectionState
      case daemonStatus
      case refreshState
      case daemonActivity
      case persistedDataAvailability
      case metrics
    }

    @ObservationIgnored public var onChanged: ((Change) -> Void)?
    public var connectionState: ConnectionState = .idle {
      didSet {
        guard oldValue != connectionState else { return }
        onChanged?(.connectionState)
      }
    }
    public var daemonStatus: DaemonStatusReport? {
      didSet {
        guard oldValue != daemonStatus else { return }
        onChanged?(.daemonStatus)
      }
    }
    public var diagnostics: DaemonDiagnosticsReport?
    public var health: HealthResponse?
    public var isRefreshing = false {
      didSet {
        guard oldValue != isRefreshing else { return }
        onChanged?(.refreshState)
      }
    }
    public var isDiagnosticsRefreshInFlight = false
    public var isDaemonActionInFlight = false {
      didSet {
        guard oldValue != isDaemonActionInFlight else { return }
        onChanged?(.daemonActivity)
      }
    }
    public var activeTransport: TransportKind = .httpSSE
    public var connectionMetrics: ConnectionMetrics = .initial {
      didSet {
        guard oldValue != connectionMetrics else { return }
        onChanged?(.metrics)
      }
    }
    public var connectionEvents: [ConnectionEvent] = []
    public var subscribedSessionIDs: Set<String> = []
    public var daemonLogLevel: String?
    public var isShowingCachedCatalog = false {
      didSet {
        guard oldValue != isShowingCachedCatalog else { return }
        onChanged?(.persistedDataAvailability)
      }
    }
    public var isShowingCachedSelectedSession = false {
      didSet {
        guard oldValue != isShowingCachedSelectedSession else { return }
        onChanged?(.persistedDataAvailability)
      }
    }
    public var isShowingCachedData: Bool {
      get { isShowingCachedSelectedSession }
      set { isShowingCachedSelectedSession = newValue }
    }
    public var persistedSessionCount = 0 {
      didSet {
        guard oldValue != persistedSessionCount else { return }
        onChanged?(.persistedDataAvailability)
      }
    }
    public var lastPersistedSnapshotAt: Date? {
      didSet {
        guard oldValue != lastPersistedSnapshotAt else { return }
        onChanged?(.persistedDataAvailability)
      }
    }
  }

  @MainActor
  @Observable
  public final class SelectionSlice {
    public enum Change {
      case selectedSessionID
      case selectedSession
      case selectedSessionDetail
      case timeline
      case timelineWindow
      case inspectorSelection
      case actionActorID
      case selectionLoading
      case timelineLoading
      case extensionsLoading
      case sessionAction
      case inFlightActionID
    }

    @ObservationIgnored public var onChanged: ((Change) -> Void)?
    @ObservationIgnored private var selectedSessionChangeOverride: Change?
    public var selectedSessionID: String? {
      didSet {
        guard oldValue != selectedSessionID else { return }
        onChanged?(.selectedSessionID)
      }
    }
    public var selectedSession: SessionDetail? {
      didSet {
        guard oldValue != selectedSession else { return }
        let change = selectedSessionChangeOverride ?? .selectedSession
        selectedSessionChangeOverride = nil
        onChanged?(change)
      }
    }
    public var timeline: [TimelineEntry] = [] {
      didSet {
        guard oldValue != timeline else { return }
        onChanged?(.timeline)
      }
    }
    public var timelineWindow: TimelineWindowResponse? {
      didSet {
        guard oldValue != timelineWindow else { return }
        onChanged?(.timelineWindow)
      }
    }
    public var inspectorSelection: InspectorSelection = .none {
      didSet {
        guard oldValue != inspectorSelection else { return }
        onChanged?(.inspectorSelection)
      }
    }
    public var actionActorID: String? {
      didSet {
        guard oldValue != actionActorID else { return }
        onChanged?(.actionActorID)
      }
    }
    public var isSelectionLoading = false {
      didSet {
        guard oldValue != isSelectionLoading else { return }
        onChanged?(.selectionLoading)
      }
    }
    public var isTimelineLoading = false {
      didSet {
        guard oldValue != isTimelineLoading else { return }
        onChanged?(.timelineLoading)
      }
    }
    public var isExtensionsLoading = false {
      didSet {
        guard oldValue != isExtensionsLoading else { return }
        onChanged?(.extensionsLoading)
      }
    }
    public var retainPresentedDetailWhenSelectionClears = false
    public var isSessionActionInFlight = false {
      didSet {
        guard oldValue != isSessionActionInFlight else { return }
        onChanged?(.sessionAction)
      }
    }
    public var inFlightActionID: String? {
      didSet {
        guard oldValue != inFlightActionID else { return }
        onChanged?(.inFlightActionID)
      }
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

    func applySelectedSession(_ detail: SessionDetail?, change: Change) {
      guard selectedSession != detail else { return }
      selectedSessionChangeOverride = change
      selectedSession = detail
    }
  }

  @MainActor
  @Observable
  public final class UserDataSlice {
    @ObservationIgnored public var onChanged: (() -> Void)?
    public var bookmarkedSessionIds: Set<String> = [] {
      didSet {
        guard oldValue != bookmarkedSessionIds else { return }
        onChanged?()
      }
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

  @MainActor
  @Observable
  public final class SessionProjectionSlice {
    public internal(set) var groupedSessions: [SessionGroup] = []
    public internal(set) var filteredSessionCount = 0
    public internal(set) var totalSessionCount = 0
    public internal(set) var emptyState: SidebarEmptyState = .noSessions

    public init() {}

    internal func apply(_ state: SessionProjectionState) {
      if self.groupedSessions != state.groupedSessions {
        self.groupedSessions = state.groupedSessions
      }
      if self.filteredSessionCount != state.filteredSessionCount {
        self.filteredSessionCount = state.filteredSessionCount
      }
      if self.totalSessionCount != state.totalSessionCount {
        self.totalSessionCount = state.totalSessionCount
      }
      if self.emptyState != state.emptyState {
        self.emptyState = state.emptyState
      }
    }

  }

  @MainActor
  @Observable
  public final class SessionSearchResultsSlice {
    public internal(set) var presentationState = SessionSearchPresentationState()
    public internal(set) var listState = SessionSearchResultsListState()
    public internal(set) var filteredSessionCount = 0
    public internal(set) var totalSessionCount = 0

    public var isSearchActive: Bool { presentationState.isSearchActive }
    public var visibleSessionIDs: [String] { listState.visibleSessionIDs }
    public var emptyState: SidebarEmptyState { presentationState.emptyState }

    public init() {}

    internal func apply(_ state: SessionSearchResultsState) {
      if presentationState != state.presentation {
        presentationState = state.presentation
      }
      if listState != state.list {
        listState = state.list
      }
      if filteredSessionCount != state.filteredSessionCount {
        filteredSessionCount = state.filteredSessionCount
      }
      if totalSessionCount != state.totalSessionCount {
        totalSessionCount = state.totalSessionCount
      }
    }
  }

  @MainActor
  public final class ContentUISlice {
    public let shell = ContentShellSlice()
    public let toolbar = ContentToolbarSlice()
    public let chrome = ContentChromeSlice()
    public let session = ContentSessionSlice()
    public let sessionDetail = ContentSessionDetailSlice()
    public let dashboard = ContentDashboardSlice()

    public init() {}
  }

  public struct ContentShellState: Equatable {
    public var connectionState: ConnectionState = .idle
    public var pendingConfirmation: PendingConfirmation?
    public var presentedSheet: PresentedSheet?
  }

  public struct ContentChromeState: Equatable {
    public var persistenceError: String?
    public var sessionDataAvailability: SessionDataAvailability = .live
    public var sessionStatus: SessionStatus?
  }

  public struct ContentSessionState: Equatable {
    public var selectedSessionSummary: SessionSummary?
    public var isSessionReadOnly = true
    public var isSessionActionInFlight = false
    public var isSelectionLoading = false
    public var isExtensionsLoading = false
    public var isTaskDragActive = false
  }

  public struct ContentSessionDetailState: Equatable {
    public var selectedSessionDetail: SessionDetail?
    public var timeline: [TimelineEntry] = []
    public var timelineWindow: TimelineWindowResponse?
    public var tuiStatusByAgent: [String: AgentTuiStatus] = [:]
    public var isTimelineLoading = false
    public var retainPresentedDetailWhenSelectionClears = false
  }

  public struct ContentDashboardState: Equatable {
    public var connectionState: ConnectionState = .idle
    public var isBusy = false
    public var isRefreshing = false
    public var isLaunchAgentInstalled = false
  }

  public struct SidebarUIState: Equatable {
    public var connectionMetrics: ConnectionMetrics = .initial
    public var selectedSessionID: String?
    public var isPersistenceAvailable = false
    public var bookmarkedSessionIds: Set<String> = []
    public var projectCount = 0
    public var worktreeCount = 0
    public var sessionCount = 0
    public var openWorkCount = 0
    public var blockedCount = 0
  }

  public struct InspectorUIState: Equatable {
    public var isPersistenceAvailable = false
    public var selectedActionActorID = ""
    public var isSessionReadOnly = true
    public var isSessionActionInFlight = false
    public var primaryContent: InspectorPrimaryContentState = .empty
    public var actionContext: InspectorActionContext?
  }

  @MainActor
  @Observable
  public final class ContentShellSlice {
    public var connectionState: ConnectionState = .idle
    public var pendingConfirmation: PendingConfirmation?
    public var presentedSheet: PresentedSheet?

    public init() {}

    internal func apply(_ state: ContentShellState) {
      if connectionState != state.connectionState {
        connectionState = state.connectionState
      }
      if pendingConfirmation != state.pendingConfirmation {
        pendingConfirmation = state.pendingConfirmation
      }
      if presentedSheet != state.presentedSheet {
        presentedSheet = state.presentedSheet
      }
    }
  }

  @MainActor
  @Observable
  public final class ContentToolbarSlice {
    public var canNavigateBack = false
    public var canNavigateForward = false
    public var isRefreshing = false
    public var sleepPreventionEnabled = false

    public init() {}
  }

}
