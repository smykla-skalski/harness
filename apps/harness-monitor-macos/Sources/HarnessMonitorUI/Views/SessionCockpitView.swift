import HarnessMonitorKit
import SwiftUI

struct SessionCockpitView: View {
  let detail: SessionDetail
  let timeline: [TimelineEntry]
  let isSessionReadOnly: Bool
  let isSessionActionInFlight: Bool
  let isSelectionLoading: Bool
  let lastAction: String
  let observeSelectedSession: () -> Void
  let requestEndSessionConfirmation: () -> Void
  let inspectTask: (String) -> Void
  let inspectAgent: (String) -> Void
  let inspectSignal: (String) -> Void
  let inspectObserver: () -> Void

  var body: some View {
    HarnessMonitorColumnScrollView {
      VStack(alignment: .leading, spacing: 16) {
        SessionCockpitHeaderCard(
          detail: detail,
          isSessionReadOnly: isSessionReadOnly,
          isSessionActionInFlight: isSessionActionInFlight,
          isSelectionLoading: isSelectionLoading,
          observeSelectedSession: observeSelectedSession,
          requestEndSessionConfirmation: requestEndSessionConfirmation,
          inspectObserver: inspectObserver
        )
        SessionMetricGrid(metrics: detail.session.metrics)
        SessionActionDock(
          detail: detail,
          isSessionActionInFlight: isSessionActionInFlight,
          lastAction: lastAction,
          inspectTask: inspectTask,
          inspectAgent: inspectAgent,
          inspectObserver: inspectObserver
        )
        HarnessMonitorAdaptiveGridLayout(minimumColumnWidth: 340, maximumColumns: 2, spacing: 16) {
          SessionTaskListSection(
            tasks: detail.tasks,
            companionAgentCount: detail.agents.count,
            inspectTask: inspectTask
          )
          SessionAgentListSection(agents: detail.agents, inspectAgent: inspectAgent)
        }
        SessionCockpitSignalsSection(signals: detail.signals, inspectSignal: inspectSignal)
        SessionCockpitTimelineSection(timeline: timeline)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(HarnessMonitorTheme.ink)
  }
}

#Preview("Cockpit") {
  SessionCockpitView(
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline,
    isSessionReadOnly: false,
    isSessionActionInFlight: false,
    isSelectionLoading: false,
    lastAction: "Observe action queued",
    observeSelectedSession: {},
    requestEndSessionConfirmation: {},
    inspectTask: { _ in },
    inspectAgent: { _ in },
    inspectSignal: { _ in },
    inspectObserver: {}
  )
}
