import HarnessMonitorKit
import SwiftUI

struct SessionCockpitView: View {
  let store: HarnessMonitorStore
  let detail: SessionDetail
  let timeline: [TimelineEntry]
  let timelineWindow: TimelineWindowResponse?
  let tuiStatusByAgent: [String: AgentTuiStatus]
  let isSessionStatusStale: Bool
  let isSessionReadOnly: Bool
  let isTimelineLoading: Bool
  let isExtensionsLoading: Bool
  let primaryContentFocusScope: Namespace.ID?
  let primaryContentPagingResponderRequest: Int
  let prefersPrimaryContentFocus: Bool
  let primaryContentPagingResponderEnabled: Bool
  @Environment(\.openWindow)
  private var openWindow

  init(
    store: HarnessMonitorStore,
    detail: SessionDetail,
    timeline: [TimelineEntry],
    timelineWindow: TimelineWindowResponse?,
    tuiStatusByAgent: [String: AgentTuiStatus],
    isSessionStatusStale: Bool,
    isSessionReadOnly: Bool,
    isTimelineLoading: Bool,
    isExtensionsLoading: Bool,
    primaryContentFocusScope: Namespace.ID? = nil,
    primaryContentPagingResponderRequest: Int = 0,
    prefersPrimaryContentFocus: Bool = false,
    primaryContentPagingResponderEnabled: Bool = false
  ) {
    self.store = store
    self.detail = detail
    self.timeline = timeline
    self.timelineWindow = timelineWindow
    self.tuiStatusByAgent = tuiStatusByAgent
    self.isSessionStatusStale = isSessionStatusStale
    self.isSessionReadOnly = isSessionReadOnly
    self.isTimelineLoading = isTimelineLoading
    self.isExtensionsLoading = isExtensionsLoading
    self.primaryContentFocusScope = primaryContentFocusScope
    self.primaryContentPagingResponderRequest = primaryContentPagingResponderRequest
    self.prefersPrimaryContentFocus = prefersPrimaryContentFocus
    self.primaryContentPagingResponderEnabled = primaryContentPagingResponderEnabled
  }

  private func openAgent(_ agentID: String) {
    store.requestWorkspaceSelection(
      .agent(sessionID: detail.session.sessionId, agentID: agentID)
    )
    openWindow(id: HarnessMonitorWindowID.workspace)
  }

  private func focusObserver() {
    store.requestWorkspaceSelection(
      .decisions(sessionID: detail.session.sessionId),
      resetDecisionFilters: true
    )
    openWindow(id: HarnessMonitorWindowID.workspace)
  }

  var body: some View {
    ViewBodySignposter.measure("SessionCockpitView") {
      HarnessMonitorColumnScrollView(
        horizontalPadding: 24,
        verticalPadding: HarnessMonitorTheme.spacingXL,
        constrainContentWidth: true,
        readableWidth: false,
        topScrollEdgeEffect: .soft,
        scrollSurfaceIdentifier: HarnessMonitorAccessibility.sessionCockpitScrollView,
        scrollSurfaceLabel: "Session cockpit scroll view",
        primaryFocusScope: primaryContentFocusScope,
        prefersDefaultFocus: prefersPrimaryContentFocus,
        pagingResponderRequest: primaryContentPagingResponderRequest,
        pagingResponderEnabled: primaryContentPagingResponderEnabled
      ) {
        VStack(alignment: .leading, spacing: 16) {
          SessionCockpitHeaderCard(
            store: store,
            detail: detail,
            observeSelectedSession: { Task { await store.observeSelectedSession() } },
            requestEndSessionConfirmation: store.requestEndSelectedSessionConfirmation,
            inspectObserver: focusObserver
          )
          if let heuristicIssues = detail.observer?.openIssues, !heuristicIssues.isEmpty {
            SessionCockpitHeuristicIssuesSection(issues: heuristicIssues)
          }
          HarnessMonitorAdaptiveGridLayout(
            minimumColumnWidth: 340,
            maximumColumns: 3,
            spacing: 16
          ) {
            taskSection
            agentSection
            signalSection
          }
          SessionCockpitTimelineSection(
            sessionID: detail.session.sessionId,
            timeline: timeline,
            timelineWindow: timelineWindow,
            decisions: store.supervisorOpenDecisions,
            isTimelineLoading: isTimelineLoading,
            store: store
          )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var taskSection: some View {
    SessionTaskListSection(
      store: store,
      sessionID: detail.session.sessionId,
      tasks: detail.tasks,
      inspectTask: openTaskActions
    )
  }

  private func openTaskActions(_ taskID: String) {
    store.presentedSheet = .taskActions(
      sessionID: detail.session.sessionId,
      taskID: taskID
    )
  }

  private var agentSection: some View {
    SessionAgentListSection(
      store: store,
      sessionID: detail.session.sessionId,
      sessionStatus: detail.session.status,
      agents: detail.agents,
      tasks: detail.tasks,
      isSessionReadOnly: isSessionReadOnly,
      openAgent: openAgent,
      tuiStatusByAgent: tuiStatusByAgent
    )
  }

  private var signalSection: some View {
    SessionCockpitSignalsSection(
      store: store,
      signals: detail.signals,
      isExtensionsLoading: isExtensionsLoading,
      isSessionReadOnly: isSessionReadOnly
    )
  }
}

#Preview("Cockpit") {
  SessionCockpitView(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline,
    timelineWindow: .fallbackMetadata(for: PreviewFixtures.timeline),
    tuiStatusByAgent: [:],
    isSessionStatusStale: false,
    isSessionReadOnly: false,
    isTimelineLoading: false,
    isExtensionsLoading: false
  )
}

#Preview("Cockpit - TUI agents") {
  SessionCockpitView(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .agentTuiOverflow),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline,
    timelineWindow: .fallbackMetadata(for: PreviewFixtures.timeline),
    tuiStatusByAgent: [:],
    isSessionStatusStale: false,
    isSessionReadOnly: false,
    isTimelineLoading: false,
    isExtensionsLoading: false
  )
}
