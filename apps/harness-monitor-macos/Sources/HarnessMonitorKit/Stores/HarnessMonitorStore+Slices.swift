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
    public var isShowingCachedData = false {
      didSet {
        guard oldValue != isShowingCachedData else { return }
        onChanged?(.persistedDataAvailability)
      }
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
      case timeline
      case inspectorSelection
      case actionActorID
      case selectionLoading
      case extensionsLoading
      case sessionAction
      case inFlightActionID
    }

    @ObservationIgnored public var onChanged: ((Change) -> Void)?
    public var selectedSessionID: String? {
      didSet {
        guard oldValue != selectedSessionID else { return }
        onChanged?(.selectedSessionID)
      }
    }
    public var selectedSession: SessionDetail? {
      didSet {
        guard oldValue != selectedSession else { return }
        onChanged?(.selectedSession)
      }
    }
    public var timeline: [TimelineEntry] = [] {
      didSet {
        guard oldValue != timeline else { return }
        onChanged?(.timeline)
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
    public var isExtensionsLoading = false {
      didSet {
        guard oldValue != isExtensionsLoading else { return }
        onChanged?(.extensionsLoading)
      }
    }
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
  }

  public struct ContentDashboardState: Equatable {
    public var connectionState: ConnectionState = .idle
    public var isBusy = false
    public var isRefreshing = false
    public var isLaunchAgentInstalled = false
  }

  public struct CommandsUIState: Equatable {
    public var canNavigateBack = false
    public var canNavigateForward = false
    public var hasSelectedSession = false
    public var isSessionReadOnly = true
    public var bookmarkTitle = "Bookmark Session"
    public var isPersistenceAvailable = false
    public var hasObserver = false
  }

  public struct SidebarUIState: Equatable {
    public var connectionMetrics: ConnectionMetrics = .initial
    public var selectedSessionID: String?
    public var isPersistenceAvailable = false
    public var bookmarkedSessionIds: Set<String> = []
    public var searchFocusRequest = 0
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

    internal func apply(_ state: ContentChromeState) {
      if persistenceError != state.persistenceError {
        persistenceError = state.persistenceError
      }
      if sessionDataAvailability != state.sessionDataAvailability {
        sessionDataAvailability = state.sessionDataAvailability
      }
      if sessionStatus != state.sessionStatus {
        sessionStatus = state.sessionStatus
      }
    }
  }

  @MainActor
  @Observable
  public final class ContentSessionSlice {
    public var selectedSessionSummary: SessionSummary?
    public var isSessionReadOnly = true
    public var isSessionActionInFlight = false
    public var isSelectionLoading = false
    public var isExtensionsLoading = false
    public var isTaskDragActive = false

    public init() {}

    internal func apply(_ state: ContentSessionState) {
      if selectedSessionSummary != state.selectedSessionSummary {
        selectedSessionSummary = state.selectedSessionSummary
      }
      if isSessionReadOnly != state.isSessionReadOnly {
        isSessionReadOnly = state.isSessionReadOnly
      }
      if isSessionActionInFlight != state.isSessionActionInFlight {
        isSessionActionInFlight = state.isSessionActionInFlight
      }
      if isSelectionLoading != state.isSelectionLoading {
        isSelectionLoading = state.isSelectionLoading
      }
      if isExtensionsLoading != state.isExtensionsLoading {
        isExtensionsLoading = state.isExtensionsLoading
      }
      if isTaskDragActive != state.isTaskDragActive {
        isTaskDragActive = state.isTaskDragActive
      }
    }
  }

  @MainActor
  @Observable
  public final class ContentSessionDetailSlice {
    public var selectedSessionDetail: SessionDetail?
    public var timeline: [TimelineEntry] = []

    public init() {}

    internal func apply(_ state: ContentSessionDetailState) {
      if selectedSessionDetail != state.selectedSessionDetail {
        selectedSessionDetail = state.selectedSessionDetail
      }
      if timeline != state.timeline {
        timeline = state.timeline
      }
    }
  }

  @MainActor
  @Observable
  public final class ContentDashboardSlice {
    public var connectionState: ConnectionState = .idle
    public var isBusy = false
    public var isRefreshing = false
    public var isLaunchAgentInstalled = false

    public init() {}

    internal func apply(_ state: ContentDashboardState) {
      if connectionState != state.connectionState {
        connectionState = state.connectionState
      }
      if isBusy != state.isBusy {
        isBusy = state.isBusy
      }
      if isRefreshing != state.isRefreshing {
        isRefreshing = state.isRefreshing
      }
      if isLaunchAgentInstalled != state.isLaunchAgentInstalled {
        isLaunchAgentInstalled = state.isLaunchAgentInstalled
      }
    }
  }

  @MainActor
  @Observable
  public final class CommandsUISlice {
    public var canNavigateBack = false
    public var canNavigateForward = false
    public var hasSelectedSession = false
    public var isSessionReadOnly = true
    public var bookmarkTitle = "Bookmark Session"
    public var isPersistenceAvailable = false
    public var hasObserver = false

    public init() {}

    internal func apply(_ state: CommandsUIState) {
      if canNavigateBack != state.canNavigateBack {
        canNavigateBack = state.canNavigateBack
      }
      if canNavigateForward != state.canNavigateForward {
        canNavigateForward = state.canNavigateForward
      }
      if hasSelectedSession != state.hasSelectedSession {
        hasSelectedSession = state.hasSelectedSession
      }
      if isSessionReadOnly != state.isSessionReadOnly {
        isSessionReadOnly = state.isSessionReadOnly
      }
      if bookmarkTitle != state.bookmarkTitle {
        bookmarkTitle = state.bookmarkTitle
      }
      if isPersistenceAvailable != state.isPersistenceAvailable {
        isPersistenceAvailable = state.isPersistenceAvailable
      }
      if hasObserver != state.hasObserver {
        hasObserver = state.hasObserver
      }
    }
  }

  @MainActor
  @Observable
  public final class SidebarUISlice {
    public var connectionMetrics: ConnectionMetrics = .initial
    public var selectedSessionID: String?
    public var isPersistenceAvailable = false
    public var bookmarkedSessionIds: Set<String> = []
    public var searchFocusRequest = 0

    public init() {}

    internal func apply(_ state: SidebarUIState) {
      if connectionMetrics != state.connectionMetrics {
        connectionMetrics = state.connectionMetrics
      }
      if selectedSessionID != state.selectedSessionID {
        selectedSessionID = state.selectedSessionID
      }
      if isPersistenceAvailable != state.isPersistenceAvailable {
        isPersistenceAvailable = state.isPersistenceAvailable
      }
      if bookmarkedSessionIds != state.bookmarkedSessionIds {
        bookmarkedSessionIds = state.bookmarkedSessionIds
      }
      if searchFocusRequest != state.searchFocusRequest {
        searchFocusRequest = state.searchFocusRequest
      }
    }
  }

  @MainActor
  @Observable
  public final class InspectorUISlice {
    public var isPersistenceAvailable = false
    public var selectedActionActorID = ""
    public var isSessionReadOnly = true
    public var isSessionActionInFlight = false
    public var primaryContent: InspectorPrimaryContentState = .empty
    public var actionContext: InspectorActionContext?

    public init() {}

    internal func apply(_ state: InspectorUIState) {
      if isPersistenceAvailable != state.isPersistenceAvailable {
        isPersistenceAvailable = state.isPersistenceAvailable
      }
      if selectedActionActorID != state.selectedActionActorID {
        selectedActionActorID = state.selectedActionActorID
      }
      if isSessionReadOnly != state.isSessionReadOnly {
        isSessionReadOnly = state.isSessionReadOnly
      }
      if isSessionActionInFlight != state.isSessionActionInFlight {
        isSessionActionInFlight = state.isSessionActionInFlight
      }
      if primaryContent != state.primaryContent {
        primaryContent = state.primaryContent
      }
      if actionContext != state.actionContext {
        actionContext = state.actionContext
      }
    }
  }
}
