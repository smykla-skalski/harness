import Foundation
import HarnessMonitorKit

extension TaskBoardOverviewView {
  var taskBoardCardContextMenuActions: TaskBoardCardContextMenuActions {
    TaskBoardCardContextMenuActions(
      selectedIDs: cardSelectionValue.selectedIDs,
      orderedVisibleIDs: currentPresentation.orderedCardIDs,
      isActionInFlight: isActionInFlight,
      canOpen: canOpenCard,
      open: openCard,
      githubURL: githubURL,
      openGitHubURL: { url in
        openURL(url)
      },
      canMove: canMoveCardContextMenuSelection,
      move: moveCardContextMenuSelection,
      deletionTargets: deletionTargets,
      canDelete: canDeleteTaskBoardCards,
      deleteTargets: onDeleteTaskBoardTargets,
      primeSelection: primeCardSelectionForContextMenu
    )
  }

  func primeCardSelectionForContextMenu(_ cardIDs: [TaskBoardCardID]) {
    let next = cardSelectionValue.selectingForContextMenu(cardIDs)
    if cardSelectionValue != next {
      cardSelectionValue = next
    }
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
        onMoveTaskBoardItems != nil
      case .inbox:
        onMoveInboxItems != nil
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
    _ = moveCards(plan.items, to: lane)
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
        openTaskBoardItem(item)
      }
    case .inbox:
      if let item = currentPresentation.inboxItem(id: cardID) {
        onOpenItem(item)
      }
    }
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
