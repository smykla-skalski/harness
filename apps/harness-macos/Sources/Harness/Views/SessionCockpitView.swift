import HarnessKit
import Observation
import SwiftUI

struct SessionCockpitView: View {
  let store: HarnessStore
  let detail: SessionDetail
  let timeline: [TimelineEntry]

  var body: some View {
    HarnessColumnScrollView {
      VStack(alignment: .leading, spacing: 16) {
        SessionCockpitHeaderCard(store: store, detail: detail)
        SessionMetricGrid(metrics: detail.session.metrics)
        SessionActionDock(store: store, detail: detail)
        HarnessAdaptiveGridLayout(minimumColumnWidth: 340, maximumColumns: 2, spacing: 16) {
          SessionTaskListSection(tasks: detail.tasks, store: store)
            .animation(.spring(duration: 0.3), value: detail.tasks)
          SessionAgentListSection(agents: detail.agents, store: store)
            .animation(.spring(duration: 0.3), value: detail.agents)
        }
        SessionCockpitSignalsSection(signals: detail.signals, store: store)
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
