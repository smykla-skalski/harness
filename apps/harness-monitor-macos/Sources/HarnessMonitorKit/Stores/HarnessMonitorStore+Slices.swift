import Foundation
import Observation
import SwiftData

extension HarnessMonitorStore {
  @MainActor
  @Observable
  public final class ConnectionSlice {
    public enum Change {
      case shellState
      case metrics
    }

    @ObservationIgnored public var onChanged: ((Change) -> Void)?
    public var connectionState: ConnectionState = .idle {
      didSet {
        guard oldValue != connectionState else { return }
        onChanged?(.shellState)
      }
    }
    public var daemonStatus: DaemonStatusReport? {
      didSet {
        guard oldValue != daemonStatus else { return }
        onChanged?(.shellState)
      }
    }
    public var diagnostics: DaemonDiagnosticsReport?
    public var health: HealthResponse?
    public var isRefreshing = false {
      didSet {
        guard oldValue != isRefreshing else { return }
        onChanged?(.shellState)
      }
    }
    public var isDiagnosticsRefreshInFlight = false
    public var isDaemonActionInFlight = false {
      didSet {
        guard oldValue != isDaemonActionInFlight else { return }
        onChanged?(.shellState)
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
        onChanged?(.shellState)
      }
    }
    public var persistedSessionCount = 0 {
      didSet {
        guard oldValue != persistedSessionCount else { return }
        onChanged?(.shellState)
      }
    }
    public var lastPersistedSnapshotAt: Date? {
      didSet {
        guard oldValue != lastPersistedSnapshotAt else { return }
        onChanged?(.shellState)
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
    public internal(set) var state = SessionSearchResultsState()

    public var isSearchActive: Bool { state.isSearchActive }
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
    public var searchFocusRequest = 0
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
