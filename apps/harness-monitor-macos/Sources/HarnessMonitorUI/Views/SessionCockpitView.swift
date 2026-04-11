import HarnessMonitorKit
import SwiftUI

struct SessionCockpitView: View {
  let store: HarnessMonitorStore
  let detail: SessionDetail
  let timeline: [TimelineEntry]
  let isSessionReadOnly: Bool
  let isExtensionsLoading: Bool
  let lastAction: String

  var body: some View {
    HarnessMonitorColumnScrollView(
      verticalPadding: HarnessMonitorTheme.spacingXL,
      constrainContentWidth: true
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
        SessionMetricGrid(metrics: detail.session.metrics)
        SessionActionDock(
          detail: detail,
          inspectTask: store.inspect(taskID:),
          inspectAgent: store.inspect(agentID:),
          inspectObserver: store.inspectObserver,
          openAgentTui: store.presentAgentTuiSheet,
          openCodexFlow: store.presentCodexFlowSheet
        )
        HarnessMonitorAdaptiveGridLayout(minimumColumnWidth: 340, maximumColumns: 2, spacing: 16) {
          SessionTaskListSection(
            store: store,
            sessionID: detail.session.sessionId,
            tasks: detail.tasks,
            companionAgentCount: detail.agents.count,
            inspectTask: store.inspect(taskID:)
          )
          SessionAgentListSection(
            store: store,
            sessionID: detail.session.sessionId,
            agents: detail.agents,
            tasks: detail.tasks,
            isSessionReadOnly: isSessionReadOnly,
            inspectAgent: store.inspect(agentID:)
          )
        }
        SessionCockpitSignalsSection(
          store: store,
          signals: detail.signals,
          isExtensionsLoading: isExtensionsLoading,
          isSessionReadOnly: isSessionReadOnly
        )
        SessionCockpitTimelineSection(
          sessionID: detail.session.sessionId,
          timeline: timeline
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

#Preview("Cockpit") {
  SessionCockpitView(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline,
    isSessionReadOnly: false,
    isExtensionsLoading: false,
    lastAction: "Observe action queued"
  )
}
