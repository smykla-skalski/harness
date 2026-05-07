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
    isExtensionsLoading: Bool
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
  }

  private func openAgent(_ agentID: String) {
    store.requestWorkspaceSelection(
      .agent(sessionID: detail.session.sessionId, agentID: agentID)
    )
    openWindow.openHarnessSessionWindow(sessionID: detail.session.sessionId)
  }

  private func focusObserver() {
    store.requestWorkspaceSelection(
      .decisions(sessionID: detail.session.sessionId),
      resetDecisionFilters: true
    )
    openWindow.openHarnessSessionWindow(sessionID: detail.session.sessionId)
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
        underlay: {
          ContentStatusBackdrop(
            status: detail.session.status,
            isStale: isSessionStatusStale
          )
        },
        content: {
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
              maximumColumns: 2,
              spacing: 16
            ) {
              taskSection
              agentSection
            }
            MonitorTimelineSection(
              host: .session(detail.session.sessionId),
              timeline: timeline,
              timelineWindow: timelineWindow,
              decisions: store.supervisorOpenDecisions,
              isTimelineLoading: isTimelineLoading,
              store: store
            )
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      )
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

}
