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
    store.requestWorkspaceSelection(
      .agent(sessionID: detail.session.sessionId, agentID: agentID)
    )
    openWindow(id: HarnessMonitorWindowID.workspace)
  }

  private func focusObserver() {
    store.requestWorkspaceSelection(.decisions(sessionID: detail.session.sessionId))
    openWindow(id: HarnessMonitorWindowID.workspace)
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
            actionHandler: store.supervisorDecisionActionHandler(),
            loadWindow: { request in
              await store.loadSelectedTimelineWindow(request: request)
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
