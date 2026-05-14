import HarnessMonitorKit
import SwiftUI

struct TaskBoardItemSection: Identifiable {
  let lane: TaskBoardInboxLane
  let items: [TaskBoardItem]

  var id: TaskBoardInboxLane { lane }
}

struct TaskBoardOverviewMetrics: Equatable {
  let controlMinHeight: CGFloat
  let iconControlMinWidth: CGFloat
  let managementPanelMinHeight: CGFloat
  let managementPanelSpacing: CGFloat

  init(fontScale: CGFloat) {
    let scale = SessionWindowFontScale.metricsScale(for: fontScale)
    controlMinHeight = max(30, 30 * min(scale, 1.35))
    iconControlMinWidth = max(32, 32 * min(scale, 1.35))
    managementPanelMinHeight = max(132, 132 * min(scale, 1.25))
    managementPanelSpacing = max(8, 8 * min(scale, 1.35))
  }
}

extension TaskBoardItem {
  var hasLinkedSessionTask: Bool {
    sessionId != nil && workItemId != nil
  }
}

extension TaskBoardInboxLane {
  var taskBoardDropStatus: TaskBoardStatus {
    switch self {
    case .needsYou:
      .planReview
    case .ready:
      .todo
    case .running:
      .inProgress
    case .review:
      .inReview
    case .blocked:
      .blocked
    case .backlog:
      .new
    }
  }
}
