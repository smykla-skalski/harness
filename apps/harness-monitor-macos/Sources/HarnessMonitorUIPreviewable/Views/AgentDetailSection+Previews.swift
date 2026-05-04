import HarnessMonitorKit
import SwiftUI

#Preview("Agent detail - runtime") {
  agentDetailPreview(
    agentID: "worker-codex",
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)
  )
}

#Preview("Agent detail - sparse") {
  let store = HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded)
  store.selectedSessionID = PreviewFixtures.singleAgentSummary.sessionId
  store.selectedSession = PreviewFixtures.singleAgentDetail
  store.timeline = []
  return agentDetailPreview(agentID: "leader-claude", store: store)
}

@MainActor
private func agentDetailPreview(agentID: String, store: HarnessMonitorStore) -> some View {
  let agent = (store.selectedSession?.agents ?? PreviewFixtures.detail.agents)
    .first(where: { $0.agentId == agentID }) ?? PreviewFixtures.detail.agents[0]
  let activity = store.selectedSession?.agentActivity.first(where: { $0.agentId == agentID })

  return AgentDetailSection(
    store: store,
    agent: agent,
    activity: activity
  )
  .padding()
  .frame(width: 960)
  .harnessPreviewSceneAppearance()
}
