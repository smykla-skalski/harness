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
        SessionCockpitSignalsSection(signals: detail.signals) { signalID in
          store.inspect(signalID: signalID)
        }
        SessionCockpitTimelineSection(timeline: timeline)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .foregroundStyle(HarnessTheme.ink)
    .animation(.easeInOut(duration: 0.18), value: detail.tasks)
    .animation(.easeInOut(duration: 0.18), value: detail.agents)
  }
}

#Preview("Cockpit") {
  SessionCockpitView(
    store: HarnessStore(daemonController: PreviewDaemonController()),
    detail: PreviewFixtures.detail,
    timeline: PreviewFixtures.timeline
  )
}
