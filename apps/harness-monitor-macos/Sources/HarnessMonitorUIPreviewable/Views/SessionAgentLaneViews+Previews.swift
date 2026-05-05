import HarnessMonitorKit
import SwiftUI

#Preview("Agent summary - TUI running") {
  SessionAgentSummaryCard(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId,
    agent: PreviewFixtures.agents[1],
    queuedTasks: [],
    isSessionReadOnly: false,
    openAgent: { _ in },
    tuiStatus: .running
  )
  .padding()
  .frame(width: 320)
}

#Preview("Agent summary - no TUI") {
  SessionAgentSummaryCard(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId,
    agent: PreviewFixtures.agents[1],
    queuedTasks: [],
    isSessionReadOnly: false,
    openAgent: { _ in },
    tuiStatus: nil
  )
  .padding()
  .frame(width: 320)
}
