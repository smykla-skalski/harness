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

private struct TimelineIdentity: Equatable {
  struct Entry: Equatable {
    let entryID: String
    let recordedAt: String
    let kind: String
    let agentID: String?
    let taskID: String?
    let summary: String
  }

  let entries: [Entry]

  init(_ timeline: [TimelineEntry]) {
    entries = timeline.map {
      Entry(
        entryID: $0.entryId,
        recordedAt: $0.recordedAt,
        kind: $0.kind,
        agentID: $0.agentId,
        taskID: $0.taskId,
        summary: $0.summary
      )
    }
  }
}

private struct TimelineWindowIdentity: Equatable {
  let revision: Int64
  let totalCount: Int
  let windowStart: Int
  let windowEnd: Int
  let hasOlder: Bool
  let hasNewer: Bool
  let unchanged: Bool

  init?(_ window: TimelineWindowResponse?) {
    guard let window else {
      return nil
    }
    revision = window.revision
    totalCount = window.totalCount
    windowStart = window.windowStart
    windowEnd = window.windowEnd
    hasOlder = window.hasOlder
    hasNewer = window.hasNewer
    unchanged = window.unchanged
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
    public var selectedSessionSession: SessionSummary?
    public var selectedSessionAgents: [AgentRegistration] = []
    public var selectedSessionTasks: [WorkItem] = []
    public var selectedSessionSignals: [SessionSignalRecord] = []
    public var selectedSessionObserver: ObserverSummary?
    public var selectedSessionAgentActivity: [AgentToolActivitySummary] = []
    public var timeline: [TimelineEntry] = []
    public var timelineWindow: TimelineWindowResponse?
    public var tuiStatusByAgent: [String: AgentTuiStatus] = [:]
    public var isTimelineLoading = false
    public var presentedSessionDetail: SessionDetail?
    public var presentedTimeline: [TimelineEntry] = []
    public var presentedTimelineWindow: TimelineWindowResponse?
    /// Filtered subset of tasks that currently require the arbitration banner.
    /// Recomputed once per apply() tick instead of per body render so content
    /// chrome readers avoid scanning the full task list on every `@Observable`
    /// invalidation.
    public private(set) var arbitrationBannerTasks: [WorkItem] = []
    private var retainedSessionDetail: SessionDetail?
    private var retainedTimeline: [TimelineEntry] = []
    private var retainedTimelineWindow: TimelineWindowResponse?
    private var selectedSessionDetailIdentity: SessionDetailIdentity?
    private var selectedTimelineIdentity = TimelineIdentity([])
    private var selectedTimelineWindowIdentity: TimelineWindowIdentity?
    private var retainedSessionDetailIdentity: SessionDetailIdentity?
    private var retainedTimelineIdentity = TimelineIdentity([])
    private var retainedTimelineWindowIdentity: TimelineWindowIdentity?
    private var presentedSessionDetailIdentity: SessionDetailIdentity?
    private var presentedTimelineIdentity = TimelineIdentity([])
    private var presentedTimelineWindowIdentity: TimelineWindowIdentity?

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
      let nextTimelineIdentity = TimelineIdentity(state.timeline)
      let nextTimelineWindowIdentity = TimelineWindowIdentity(state.timelineWindow)
      let didUpdateSelectedTimeline = selectedTimelineIdentity != nextTimelineIdentity
      let didUpdateSelectedDetail = selectedSessionDetailIdentity != nextSelectedIdentity

      if didUpdateSelectedDetail {
        selectedSessionDetail = state.selectedSessionDetail
        narrowlyWriteSelectedSessionSubSlices(from: state.selectedSessionDetail)
      }
      if selectedSessionDetailIdentity != nextSelectedIdentity {
        selectedSessionDetailIdentity = nextSelectedIdentity
      }
      if didUpdateSelectedTimeline {
        timeline = state.timeline
        selectedTimelineIdentity = nextTimelineIdentity
      }
      if selectedTimelineWindowIdentity != nextTimelineWindowIdentity {
        timelineWindow = state.timelineWindow
        selectedTimelineWindowIdentity = nextTimelineWindowIdentity
      }
      if tuiStatusByAgent != state.tuiStatusByAgent {
        tuiStatusByAgent = state.tuiStatusByAgent
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
      if didUpdateRetainedIdentity {
        retainedSessionDetail = detail
      }
      if didUpdateRetainedIdentity {
        retainedSessionDetailIdentity = nextSelectedIdentity
      }
      if didUpdateRetainedIdentity || didUpdateSelectedTimeline {
        retainedTimeline = timeline
        retainedTimelineIdentity = selectedTimelineIdentity
      }
      if retainedTimelineWindowIdentity != selectedTimelineWindowIdentity {
        retainedTimelineWindow = timelineWindow
        retainedTimelineWindowIdentity = selectedTimelineWindowIdentity
      }
    }

    private func clearRetainedDetail() {
      if retainedSessionDetail != nil {
        retainedSessionDetail = nil
        retainedSessionDetailIdentity = nil
      }
      if retainedTimelineIdentity != TimelineIdentity([]) {
        retainedTimeline = []
        retainedTimelineIdentity = TimelineIdentity([])
      }
      if retainedTimelineWindowIdentity != nil {
        retainedTimelineWindow = nil
        retainedTimelineWindowIdentity = nil
      }
    }

    private func narrowlyWriteSelectedSessionSubSlices(from detail: SessionDetail?) {
      let nextSession = detail?.session
      let nextAgents = detail?.agents ?? []
      let nextTasks = detail?.tasks ?? []
      let nextSignals = detail?.signals ?? []
      let nextObserver = detail?.observer
      let nextAgentActivity = detail?.agentActivity ?? []
      if selectedSessionSession != nextSession {
        selectedSessionSession = nextSession
      }
      if selectedSessionAgents != nextAgents {
        selectedSessionAgents = nextAgents
      }
      if selectedSessionTasks != nextTasks {
        selectedSessionTasks = nextTasks
      }
      if selectedSessionSignals != nextSignals {
        selectedSessionSignals = nextSignals
      }
      if selectedSessionObserver != nextObserver {
        selectedSessionObserver = nextObserver
      }
      if selectedSessionAgentActivity != nextAgentActivity {
        selectedSessionAgentActivity = nextAgentActivity
      }
    }

    private func updatePresentedValues(
      sessionDetail: SessionDetail?,
      timeline: [TimelineEntry],
      timelineWindow: TimelineWindowResponse?
    ) {
      let nextDetailIdentity = SessionDetailIdentity(sessionDetail)
      let nextTimelineIdentity = TimelineIdentity(timeline)
      let nextTimelineWindowIdentity = TimelineWindowIdentity(timelineWindow)
      if presentedSessionDetailIdentity != nextDetailIdentity {
        presentedSessionDetail = sessionDetail
        presentedSessionDetailIdentity = nextDetailIdentity
      }
      if presentedTimelineIdentity != nextTimelineIdentity {
        presentedTimeline = timeline
        presentedTimelineIdentity = nextTimelineIdentity
      }
      if presentedTimelineWindowIdentity != nextTimelineWindowIdentity {
        presentedTimelineWindow = timelineWindow
        presentedTimelineWindowIdentity = nextTimelineWindowIdentity
      }
      let nextArbitrationTasks =
        sessionDetail?.tasks.filter(\.requiresArbitrationBanner) ?? []
      if arbitrationBannerTasks != nextArbitrationTasks {
        arbitrationBannerTasks = nextArbitrationTasks
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
