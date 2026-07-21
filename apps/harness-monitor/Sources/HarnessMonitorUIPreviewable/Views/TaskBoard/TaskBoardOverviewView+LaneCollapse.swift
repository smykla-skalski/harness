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

  /// Lanes currently collapsed on this board, used to flag an umbrella's
  /// children that are technically loaded but not visible in any lane today.
  var collapsedLanesValue: Set<TaskBoardInboxLane> {
    Set(
      TaskBoardInboxLane.allCases.filter { lane in
        let apiItems = currentPresentation.apiItems(in: lane)
        let inboxItems = currentPresentation.inboxItems(in: lane)
        let contentCount = laneContentCount(
          apiItems: apiItems,
          inboxItems: inboxItems,
          decisions: decisions(in: lane)
        )
        return isLaneCollapsed(lane, contentCount: contentCount)
      }
    )
  }
}
