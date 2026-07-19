import HarnessMonitorKit

extension TaskBoardOverviewView {
  func laneContentCount(
    apiItems: [TaskBoardItem],
    inboxItems: [TaskBoardInboxItem],
    decisions: [Decision]
  ) -> Int {
    apiItems.count + inboxItems.count + decisions.count
  }

  func isLaneCollapsed(_ lane: TaskBoardInboxLane, contentCount: Int) -> Bool {
    TaskBoardLaneCollapsePreferences.isCollapsed(
      lane: lane,
      contentCount: contentCount,
      rawValue: laneCollapsePreferencesRawValue
    )
  }
}
