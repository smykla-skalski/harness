import HarnessMonitorKit
import SwiftUI

struct SessionPerfStaticDetailSurface: View {
  let route: SessionWindowRoute
  let selection: SessionSelection

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(route.title, systemImage: route.systemImage)
        .scaledFont(.body.weight(.semibold))
      Text(selectionLabel)
        .scaledFont(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.background)
    .onAppear {
      HarnessMonitorPerfTrace.recordScenarioEvent(
        component: "perf.detail",
        event: "static-detail.appear",
        details: [
          "route": route.rawValue,
          "selection": selectionLabel,
        ]
      )
    }
  }

  private var selectionLabel: String {
    switch selection {
    case .route(let route):
      "route.\(route.rawValue)"
    case .agent(_, let agentID):
      "agent.\(agentID)"
    case .decision(_, let decisionID):
      "decision.\(decisionID)"
    case .task(_, let taskID):
      "task.\(taskID)"
    case .codexRun(_, let runID):
      "codex.\(runID)"
    case .create(let draft):
      "create.\(draft.kind.rawValue)"
    }
  }
}
