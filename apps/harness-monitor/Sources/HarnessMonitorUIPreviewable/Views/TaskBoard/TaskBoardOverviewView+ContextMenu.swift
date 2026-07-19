import Foundation
import HarnessMonitorKit

extension TaskBoardOverviewView {
  var taskBoardCardContextMenuActions: TaskBoardCardContextMenuActions {
    let deleteTargetsAction: (([TaskBoardDeletionTarget]) -> Void)? =
      actions.canDeleteTargets
      ? { targets in actions.deleteTaskBoardTargets(targets) }
      : nil
    return TaskBoardCardContextMenuActions(
      selectedIDs: selectionModelValue.selectedIDs,
      orderedVisibleIDs: currentPresentation.orderedCardIDs,
      isActionInFlight: isActionInFlight,
      canOpen: canOpenCard,
      open: openCard,
      canOpenAgent: canOpenSpawnedAgent,
      openAgent: openSpawnedAgent,
      githubURL: githubURL,
      openGitHubURL: { url in
        openURL(url)
      },
      canMove: canMoveCardContextMenuSelection,
      move: moveCardContextMenuSelection,
      deletionTargets: deletionTargets,
      canDelete: canDeleteTaskBoardCards,
      deleteTargets: deleteTargetsAction,
      primeSelection: primeCardSelectionForContextMenu
    )
  }

  func primeCardSelectionForContextMenu(_ cardIDs: [TaskBoardCardID]) {
    selectionModelValue.primeForContextMenu(cardIDs)
  }

  private func canMoveCardContextMenuSelection(
    _ cardIDs: [TaskBoardCardID],
    to lane: TaskBoardInboxLane
  ) -> Bool {
    guard !isActionInFlight, let plan = cardContextMenuMovePlan(cardIDs, to: lane) else {
      return false
    }
    return plan.items.allSatisfy { item in
      switch item {
      case .api:
        actions.canMoveTaskBoardItems
      case .inbox:
        actions.canMoveInboxItems
      }
    }
  }

  private func moveCardContextMenuSelection(
    _ cardIDs: [TaskBoardCardID],
    to lane: TaskBoardInboxLane
  ) {
    guard let plan = cardContextMenuMovePlan(cardIDs, to: lane) else {
      return
    }
    actions.moveCardsOrReportRejection(
      plan.items,
      to: lane,
      liveInboxItems: liveInboxItemsValue
    )
  }

  private func cardContextMenuMovePlan(
    _ cardIDs: [TaskBoardCardID],
    to lane: TaskBoardInboxLane
  ) -> TaskBoardCardDropPlan? {
    TaskBoardCardDropPlan.resolve(cardDragPayloads(cardIDs), to: lane)
  }

  private func canOpenCard(_ cardID: TaskBoardCardID) -> Bool {
    switch cardID {
    case .api(let itemID):
      currentPresentation.taskBoardItem(id: itemID) != nil
    case .inbox:
      currentPresentation.inboxItem(id: cardID) != nil
    }
  }

  private func openCard(_ cardID: TaskBoardCardID) {
    switch cardID {
    case .api(let itemID):
      if let item = currentPresentation.taskBoardItem(id: itemID) {
        selectionModelValue.openAPIItem(item, actions: actions)
      }
    case .inbox:
      if let item = currentPresentation.inboxItem(id: cardID) {
        actions.openInboxItem(item)
      }
    }
  }

  private func spawnedSessionLink(
    for cardID: TaskBoardCardID
  ) -> (sessionID: String, workItemID: String?)? {
    switch cardID {
    case .api(let itemID):
      guard
        let item = currentPresentation.taskBoardItem(id: itemID),
        let sessionID = item.sessionId,
        !sessionID.isEmpty
      else {
        return nil
      }
      return (sessionID, item.workItemId)
    case .inbox(let sessionID, let taskID):
      return sessionID.isEmpty ? nil : (sessionID, taskID)
    }
  }

  func canOpenSpawnedAgent(_ cardID: TaskBoardCardID) -> Bool {
    store != nil && spawnedSessionLink(for: cardID) != nil
  }

  func openSpawnedAgent(_ cardID: TaskBoardCardID) {
    guard let store, let link = spawnedSessionLink(for: cardID) else {
      return
    }
    TaskBoardSpawnedSessionNavigator.open(
      store: store,
      openWindow: openWindow,
      sessionID: link.sessionID,
      workItemID: link.workItemID
    )
  }

  private func githubURL(for cardID: TaskBoardCardID) -> URL? {
    guard case .api(let itemID) = cardID else {
      return nil
    }
    return currentPresentation.taskBoardItem(id: itemID)?.taskBoardGitHubURL
  }

  func deletionTargets(
    for cardIDs: [TaskBoardCardID]
  ) -> [TaskBoardDeletionTarget] {
    cardIDs.compactMap { cardID in
      switch cardID {
      case .api(let itemID):
        currentPresentation.taskBoardItem(id: itemID).map(
          TaskBoardDeletionTarget.init(taskBoardItem:)
        )
      case .inbox:
        currentPresentation.inboxItem(id: cardID).map(
          TaskBoardDeletionTarget.init(inboxTask:)
        )
      }
    }
  }
}
