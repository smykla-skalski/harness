import HarnessMonitorKit
import SwiftUI
import UniformTypeIdentifiers

#Preview("Task summary") {
  SessionTaskSummaryCard(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId,
    task: PreviewFixtures.tasks[0],
    inspectTask: { _ in }
  )
  .padding()
  .frame(width: 320)
}
