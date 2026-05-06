import HarnessMonitorKit
import SwiftUI

#Preview("Task actions sheet") {
  TaskActionsSheet(
    store: HarnessMonitorPreviewStoreFactory.makeStore(for: .cockpitLoaded),
    sessionID: PreviewFixtures.summary.sessionId,
    taskID: PreviewFixtures.tasks[0].taskId
  )
  .frame(width: 520, height: 620)
}
