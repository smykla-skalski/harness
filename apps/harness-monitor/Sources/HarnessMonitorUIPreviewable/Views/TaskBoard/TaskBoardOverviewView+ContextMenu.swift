import Foundation
import HarnessMonitorKit

struct TaskBoardCardContextMenuEdgeMoveContext {
  let item: TaskBoardItem
  let lane: TaskBoardInboxLane
  let orderedItemIDs: [String]

  static func resolve(
    cardID: TaskBoardCardID,
    canonicalItems: [TaskBoardItem]
  ) -> Self? {
    guard case .api(let itemID) = cardID else { return nil }
    guard
      let item = canonicalItems.first(where: { $0.id == itemID }),
      item.kind != .umbrella,
      let lane = TaskBoardInboxLane(taskBoardItem: item)
    else {
      return nil
    }
    return Self(
      item: item,
      lane: lane,
      orderedItemIDs: canonicalItems.compactMap { candidate in
        TaskBoardInboxLane(taskBoardItem: candidate) == lane
          ? candidate.id
          : nil
      }
    )
  }
}

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
      canMoveToEdge: canMoveCardContextMenuItemToEdge,
      moveToEdge: moveCardContextMenuItemToEdge,
      canResetPosition: canResetCardPosition,
      resetPosition: resetCardPosition,
      deletionTargets: deletionTargets,
      canDelete: canDeleteTaskBoardCards,
      deleteTargets: deleteTargetsAction,
      primeSelection: primeCardSelectionForContextMenu
    )
  }

  private func canMoveCardContextMenuItemToEdge(
    _ cardID: TaskBoardCardID,
    edge: TaskBoardCardContextMenuEdge
  ) -> Bool {
    guard
      !isActionInFlight,
      actions.canMoveTaskBoardItems,
      let context = cardContextMenuEdgeMoveContext(cardID)
    else {
      return false
    }
    return !edge.isCurrentEdge(
      itemID: context.item.id,
      orderedItemIDs: context.orderedItemIDs
    )
  }

  private func moveCardContextMenuItemToEdge(
    _ cardID: TaskBoardCardID,
    edge: TaskBoardCardContextMenuEdge
  ) {
    guard
      canMoveCardContextMenuItemToEdge(cardID, edge: edge),
      let context = cardContextMenuEdgeMoveContext(cardID)
    else {
      return
    }
    let placement: TaskBoardLanePlacement
    let revealAnchor: TaskBoardLaneRevealAnchor
    switch edge {
    case .top:
      placement = .first
      revealAnchor = .top
    case .bottom:
      placement = .last
      revealAnchor = .bottom
    }
    let moved = actions.reorderTaskBoardItem(
      TaskBoardCardReorderPlan(
        itemID: context.item.id,
        sourceStatus: context.item.status,
        destinationStatus: context.item.status,
        placement: placement
      )
    )
    guard moved else { return }
    requestLaneReveal(
      cardID: cardID,
      in: context.lane,
      anchor: revealAnchor
    )
    applyImmediateTaskBoardPositionProjection()
  }

  private func cardContextMenuEdgeMoveContext(
    _ cardID: TaskBoardCardID
  ) -> TaskBoardCardContextMenuEdgeMoveContext? {
    TaskBoardCardContextMenuEdgeMoveContext.resolve(
      cardID: cardID,
      canonicalItems: allKnownTaskBoardItems
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
    _ primaryID: TaskBoardCardID,
    _ cardIDs: [TaskBoardCardID],
    to lane: TaskBoardInboxLane
  ) {
    guard let plan = cardContextMenuMovePlan(cardIDs, to: lane) else {
      return
    }
    let moved = actions.moveCardsOrReportRejection(
      plan.items,
      to: lane,
      liveInboxItems: liveInboxItemsValue
    )
    if moved {
      requestLaneReveal(cardID: primaryID, in: lane, anchor: .minimal)
    }
  }

  private func canResetCardPosition(_ cardID: TaskBoardCardID) -> Bool {
    guard case .api(let itemID) = cardID, let item = currentPresentation.taskBoardItem(id: itemID)
    else {
      return false
    }
    if case .manual = item.laneOrigin {
      return actions.canMoveTaskBoardItems
    }
    return false
  }

  private func resetCardPosition(_ cardID: TaskBoardCardID) {
    guard case .api(let itemID) = cardID, let item = currentPresentation.taskBoardItem(id: itemID)
    else {
      return
    }
    actions.resetTaskBoardItemPosition(item)
  }

  private func cardContextMenuMovePlan(
    _ cardIDs: [TaskBoardCardID],
    to lane: TaskBoardInboxLane
  ) -> TaskBoardCardDropPlan? {
    TaskBoardCardDropPlan.resolve(cardDragPayloads(cardIDs), to: lane)
  }

  func canOpenCard(_ cardID: TaskBoardCardID) -> Bool {
    switch cardID {
    case .api(let itemID):
      currentPresentation.taskBoardItem(id: itemID) != nil
    case .inbox:
      currentPresentation.inboxItem(id: cardID) != nil
    }
  }

  func openCard(_ cardID: TaskBoardCardID) {
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
    switch cardID {
    case .api(let itemID):
      guard let item = currentPresentation.taskBoardItem(id: itemID) else {
        return false
      }
      return actions.canOpenSpawnedTask(item)
    case .inbox:
      return store != nil && spawnedSessionLink(for: cardID) != nil
    }
  }

  func openSpawnedAgent(_ cardID: TaskBoardCardID) {
    switch cardID {
    case .api(let itemID):
      guard let item = currentPresentation.taskBoardItem(id: itemID) else { return }
      actions.openSpawnedTask(item, openWindow: openWindow)
    case .inbox:
      guard let store, let link = spawnedSessionLink(for: cardID) else { return }
      TaskBoardSpawnedSessionNavigator.open(
        store: store,
        openWindow: openWindow,
        sessionID: link.sessionID,
        workItemID: link.workItemID
      )
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
