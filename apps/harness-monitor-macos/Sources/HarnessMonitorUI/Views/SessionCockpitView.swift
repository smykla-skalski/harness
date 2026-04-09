import HarnessMonitorKit
import SwiftUI

struct SessionCockpitView: View {
  let store: HarnessMonitorStore
  let detail: SessionDetail
  let timeline: [TimelineEntry]
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let isSelectionLoading: Bool
  let isExtensionsLoading: Bool
  let lastAction: String

  var body: some View {
    HarnessMonitorColumnScrollView(
      verticalPadding: HarnessMonitorTheme.spacingXL,
      constrainContentWidth: true
    ) {
      VStack(alignment: .leading, spacing: 16) {
        SessionCockpitHeaderCard(
          detail: detail,
          isSessionReadOnly: isSessionReadOnly,
          isSessionActionInFlight: isSessionActionInFlight,
          isSelectionLoading: isSelectionLoading,
          isExtensionsLoading: isExtensionsLoading,
          observeSelectedSession: { Task { await store.observeSelectedSession() } },
          requestEndSessionConfirmation: store.requestEndSelectedSessionConfirmation,
          inspectObserver: store.inspectObserver
        )
        SessionMetricGrid(metrics: detail.session.metrics)
        SessionActionDock(
          detail: detail,
          isSessionActionInFlight: isSessionActionInFlight,
          lastAction: lastAction,
          inspectTask: store.inspect(taskID:),
          inspectAgent: store.inspect(agentID:),
          inspectObserver: store.inspectObserver,
          openCodexFlow: store.presentCodexFlowSheet
        )
        HarnessMonitorAdaptiveGridLayout(minimumColumnWidth: 340, maximumColumns: 2, spacing: 16) {
          SessionTaskListSection(
            tasks: detail.tasks,
            companionAgentCount: detail.agents.count,
            inspectTask: store.inspect(taskID:)
          )
          SessionAgentListSection(
            store: store,
            agents: detail.agents,
            inspectAgent: store.inspect(agentID:)
          )
        }
        SessionCockpitSignalsSection(
          signals: detail.signals,
          isExtensionsLoading: isExtensionsLoading,
          inspectSignal: store.inspect(signalID:)
        )
        SessionCockpitTimelineSection(
          sessionID: detail.session.sessionId,
          timeline: timeline
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(HarnessMonitorTheme.ink)
  }
}

#Preview("Cockpit") {
  SessionCockpitView(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline,
    isSessionReadOnly: false,
    isSessionActionInFlight: false,
    isSelectionLoading: false,
    isExtensionsLoading: false,
    lastAction: "Observe action queued"
  )
}
