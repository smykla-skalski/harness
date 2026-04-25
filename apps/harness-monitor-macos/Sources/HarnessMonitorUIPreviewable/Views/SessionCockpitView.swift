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

  private func openAgent(_ agentID: String) {
    store.requestAgentsWindowSelection(.agent(agentID))
    openWindow(id: HarnessMonitorWindowID.agents)
  }

  var body: some View {
    ViewBodySignposter.measure("SessionCockpitView") {
      HarnessMonitorColumnScrollView(
        horizontalPadding: 24,
        verticalPadding: HarnessMonitorTheme.spacingXL,
        constrainContentWidth: true,
        readableWidth: false,
        topScrollEdgeEffect: .soft
      ) {
        VStack(alignment: .leading, spacing: 16) {
          SessionCockpitHeaderCard(
            store: store,
            detail: detail,
            isSessionReadOnly: isSessionReadOnly,
            observeSelectedSession: { Task { await store.observeSelectedSession() } },
            requestEndSessionConfirmation: store.requestEndSelectedSessionConfirmation,
            inspectObserver: store.inspectObserver
          )
          SessionMetricGrid(
            metrics: detail.session.metrics
          )
          SessionActionDock(
            detail: detail,
            inspectTask: store.inspect(taskID:),
            inspectObserver: store.inspectObserver,
            openAgents: { openWindow(id: HarnessMonitorWindowID.agents) }
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
          SessionCockpitSignalsSection(
            store: store,
            signals: detail.signals,
            isExtensionsLoading: isExtensionsLoading,
            isSessionReadOnly: isSessionReadOnly
          )
          SessionCockpitTimelineSection(
            sessionID: detail.session.sessionId,
            timeline: timeline,
            timelineWindow: timelineWindow,
            isTimelineLoading: isTimelineLoading,
            loadPage: { page, pageSize in
              await store.loadSelectedTimelinePage(page: page, pageSize: pageSize)
            }
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
      inspectTask: store.inspect(taskID:)
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
