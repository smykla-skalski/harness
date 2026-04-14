import Foundation
import Observation

private struct SessionDetailIdentity: Equatable {
  let sessionID: String
  let updatedAt: String

  init?(_ detail: SessionDetail?) {
    guard let detail else {
      return nil
    }

    sessionID = detail.session.sessionId
    updatedAt = detail.session.updatedAt
  }
}

extension HarnessMonitorStore {
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
    public var timelineWindow: TimelineWindowResponse?
    public var isTimelineLoading = false
    public var presentedSessionDetail: SessionDetail?
    public var presentedTimeline: [TimelineEntry] = []
    public var presentedTimelineWindow: TimelineWindowResponse?
    private var selectedSessionDetailIdentity: SessionDetailIdentity?
    private var presentedSessionDetailIdentity: SessionDetailIdentity?

    public init() {}

    internal func apply(
      _ state: ContentSessionDetailState,
      selectedSessionSummary: SessionSummary?
    ) {
      let nextSelectedIdentity = SessionDetailIdentity(state.selectedSessionDetail)

      if selectedSessionDetailIdentity != nextSelectedIdentity {
        selectedSessionDetail = state.selectedSessionDetail
        selectedSessionDetailIdentity = nextSelectedIdentity
      }
      if timeline != state.timeline {
        timeline = state.timeline
      }
      if timelineWindow != state.timelineWindow {
        timelineWindow = state.timelineWindow
      }
      if isTimelineLoading != state.isTimelineLoading {
        isTimelineLoading = state.isTimelineLoading
      }

      if let detail = state.selectedSessionDetail {
        if presentedSessionDetailIdentity != nextSelectedIdentity {
          presentedSessionDetail = detail
          presentedSessionDetailIdentity = nextSelectedIdentity
        }
        if presentedTimeline != state.timeline {
          presentedTimeline = state.timeline
        }
        if presentedTimelineWindow != state.timelineWindow {
          presentedTimelineWindow = state.timelineWindow
        }
        return
      }

      guard presentedSessionDetail?.session.sessionId == selectedSessionSummary?.sessionId else {
        if presentedSessionDetail != nil {
          presentedSessionDetail = nil
          presentedSessionDetailIdentity = nil
        }
        if !presentedTimeline.isEmpty {
          presentedTimeline = []
        }
        if presentedTimelineWindow != nil {
          presentedTimelineWindow = nil
        }
        return
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
