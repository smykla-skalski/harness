import HarnessKit
import Observation
import SwiftUI

struct SessionCockpitView: View {
  @Bindable var store: HarnessStore
  let detail: SessionDetail
  let timeline: [TimelineEntry]

  var body: some View {
    HarnessColumnScrollView {
      VStack(alignment: .leading, spacing: 18) {
        SessionCockpitHeaderCard(store: store, detail: detail)
        SessionMetricGrid(metrics: detail.session.metrics)
        SessionActionDock(store: store, detail: detail)
        HarnessAdaptiveGridLayout(minimumColumnWidth: 340, maximumColumns: 2, spacing: 16) {
          SessionTaskListSection(tasks: detail.tasks) { taskID in
            store.inspect(taskID: taskID)
          }
          SessionAgentListSection(agents: detail.agents) { agentID in
            store.inspect(agentID: agentID)
          }
        }
        .animation(.spring(duration: 0.3), value: detail.tasks)
        .animation(.spring(duration: 0.3), value: detail.agents)
        SessionCockpitSignalsSection(signals: detail.signals) { signalID in
          store.inspect(signalID: signalID)
        }
        .animation(.spring(duration: 0.3), value: detail.signals)
        SessionCockpitTimelineSection(timeline: timeline)
          .animation(.spring(duration: 0.3), value: timeline)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(HarnessTheme.ink)
  }
}

#Preview("Cockpit") {
  SessionCockpitView(
    store: HarnessStore(daemonController: PreviewDaemonController()),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline
  )
}
