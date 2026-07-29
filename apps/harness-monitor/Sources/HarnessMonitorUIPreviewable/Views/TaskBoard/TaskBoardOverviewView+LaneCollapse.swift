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

  func requestLaneReveal(
    cardID: TaskBoardCardID,
    in lane: TaskBoardInboxLane,
    anchor: TaskBoardLaneRevealAnchor
  ) {
    let apiItems = currentPresentation.apiItems(in: lane)
    let inboxItems = currentPresentation.inboxItems(in: lane)
    let priorDestinationCardIDs =
      apiItems.map { TaskBoardCardID.api($0.id) }
      + inboxItems.map {
        TaskBoardCardID.inbox(
          sessionID: $0.session.sessionId,
          taskID: $0.task.taskId
        )
      }
    let contentCount = laneContentCount(
      apiItems: apiItems,
      inboxItems: inboxItems,
      decisions: decisions(in: lane)
    )
    if isLaneCollapsed(lane, contentCount: contentCount) {
      laneCollapsePreferencesRawValue = TaskBoardLaneCollapsePreferences.expandedRawValue(
        lane: lane,
        rawValue: laneCollapsePreferencesRawValue
      )
    }
    laneRevealCoordinatorValue.request(
      cardID: cardID,
      in: lane,
      anchor: anchor,
      priorDestinationCardIDs: priorDestinationCardIDs
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
