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
    private var retainedSessionDetail: SessionDetail?
    private var retainedTimeline: [TimelineEntry] = []
    private var retainedTimelineWindow: TimelineWindowResponse?
    private var selectedSessionDetailIdentity: SessionDetailIdentity?
    private var retainedSessionDetailIdentity: SessionDetailIdentity?

    public init() {}

    internal func apply(
      _ state: ContentSessionDetailState,
      selectedSessionSummary: SessionSummary?
    ) {
      let nextSelectedIdentity = SessionDetailIdentity(state.selectedSessionDetail)
      let didUpdateSelectedTimeline = applySelectedDetail(state, identity: nextSelectedIdentity)

      if let detail = state.selectedSessionDetail {
        updateRetainedDetail(
          with: detail,
          identity: nextSelectedIdentity,
          didUpdateSelectedTimeline: didUpdateSelectedTimeline
        )
        updatePresentedValues(
          sessionDetail: detail,
          timeline: timeline,
          timelineWindow: timelineWindow
        )
        return
      }

      // Fresh detail is not in place. The retained cockpit is kept alive so the
      // detail scene does not teardown mid-transition; it is only released when
      // the store marks the detail as non-retainable (e.g. the session was
      // removed) or the selection returns to the dashboard.
      let shouldDropRetainedDetail =
        !state.retainPresentedDetailWhenSelectionClears || selectedSessionSummary == nil
      if shouldDropRetainedDetail {
        clearRetainedDetail()
        updatePresentedValues(sessionDetail: nil, timeline: [], timelineWindow: nil)
      } else {
        updatePresentedValues(
          sessionDetail: retainedSessionDetail,
          timeline: retainedTimeline,
          timelineWindow: retainedTimelineWindow
        )
      }
    }

    private func applySelectedDetail(
      _ state: ContentSessionDetailState,
      identity nextSelectedIdentity: SessionDetailIdentity?
    ) -> Bool {
      let didUpdateSelectedTimeline = timeline != state.timeline
      let didUpdateSelectedDetail = selectedSessionDetail != state.selectedSessionDetail

      if didUpdateSelectedDetail {
        selectedSessionDetail = state.selectedSessionDetail
      }
      if selectedSessionDetailIdentity != nextSelectedIdentity {
        selectedSessionDetailIdentity = nextSelectedIdentity
      }
      if didUpdateSelectedTimeline {
        timeline = state.timeline
      }
      if timelineWindow != state.timelineWindow {
        timelineWindow = state.timelineWindow
      }
      if isTimelineLoading != state.isTimelineLoading {
        isTimelineLoading = state.isTimelineLoading
      }
      return didUpdateSelectedTimeline
    }

    private func updateRetainedDetail(
      with detail: SessionDetail,
      identity nextSelectedIdentity: SessionDetailIdentity?,
      didUpdateSelectedTimeline: Bool
    ) {
      let didUpdateRetainedIdentity = retainedSessionDetailIdentity != nextSelectedIdentity
      let didUpdateRetainedDetail = retainedSessionDetail != detail
      if didUpdateRetainedDetail {
        retainedSessionDetail = detail
      }
      if didUpdateRetainedIdentity {
        retainedSessionDetailIdentity = nextSelectedIdentity
      }
      if didUpdateRetainedIdentity || didUpdateSelectedTimeline {
        retainedTimeline = timeline
      }
      if retainedTimelineWindow != timelineWindow {
        retainedTimelineWindow = timelineWindow
      }
    }

    private func clearRetainedDetail() {
      if retainedSessionDetail != nil {
        retainedSessionDetail = nil
        retainedSessionDetailIdentity = nil
      }
      if !retainedTimeline.isEmpty {
        retainedTimeline = []
      }
      if retainedTimelineWindow != nil {
        retainedTimelineWindow = nil
      }
    }

    private func updatePresentedValues(
      sessionDetail: SessionDetail?,
      timeline: [TimelineEntry],
      timelineWindow: TimelineWindowResponse?
    ) {
      if presentedSessionDetail != sessionDetail { presentedSessionDetail = sessionDetail }
      if presentedTimeline != timeline { presentedTimeline = timeline }
      if presentedTimelineWindow != timelineWindow { presentedTimelineWindow = timelineWindow }
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
    public var projectCount = 0
    public var worktreeCount = 0
    public var sessionCount = 0
    public var openWorkCount = 0
    public var blockedCount = 0

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
      if projectCount != state.projectCount {
        projectCount = state.projectCount
      }
      if worktreeCount != state.worktreeCount {
        worktreeCount = state.worktreeCount
      }
      if sessionCount != state.sessionCount {
        sessionCount = state.sessionCount
      }
      if openWorkCount != state.openWorkCount {
        openWorkCount = state.openWorkCount
      }
      if blockedCount != state.blockedCount {
        blockedCount = state.blockedCount
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
