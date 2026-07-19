import HarnessMonitorKit
import SwiftUI

extension SessionWindowOverview {
  /// Equatable key that changes exactly when the inputs to
  /// `makeTaskBoardSnapshot()` change: the session summary (title, status,
  /// metrics) or the detail's tasks. Deliberately keys on the whole
  /// `detail` rather than just `detail?.tasks` - a slightly larger key that
  /// can never miss a task mutation, at the cost of occasionally
  /// recomputing on unrelated detail changes (agents, signals).
  struct TaskBoardSnapshotKey: Equatable {
    let summary: SessionSummary
    let detail: SessionDetail?
    let isFromCache: Bool
  }

  var taskBoardSnapshotKey: TaskBoardSnapshotKey {
    TaskBoardSnapshotKey(
      summary: snapshot.summary,
      detail: snapshot.detail,
      isFromCache: snapshot.source != .live
    )
  }

  /// Not free - flatMap + sort. Callers must run this off the body path,
  /// keyed on `taskBoardSnapshotKey`, and cache the result.
  func makeTaskBoardSnapshot() -> TaskBoardInboxSnapshot {
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
