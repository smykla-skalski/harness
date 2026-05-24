import HarnessMonitorKit
import SwiftUI

extension SessionWindowOverview {
  var taskBoardSnapshot: TaskBoardInboxSnapshot {
    guard let detail = snapshot.detail else {
      return TaskBoardInboxSnapshot(
        generatedAt: nil,
        isFromCache: snapshot.source != .live
      )
    }
    return TaskBoardInboxSnapshot(
      sessions: [snapshot.summary],
      detailsBySessionID: [snapshot.summary.sessionId: detail],
      generatedAt: nil,
      isFromCache: snapshot.source != .live
    )
  }

  var taskBoardSourceItems: [TaskBoardItem] {
    let dashboardItems = store.contentUI.dashboard.taskBoardItems
    return dashboardItems.isEmpty ? snapshot.taskBoardItems ?? [] : dashboardItems
  }
}
