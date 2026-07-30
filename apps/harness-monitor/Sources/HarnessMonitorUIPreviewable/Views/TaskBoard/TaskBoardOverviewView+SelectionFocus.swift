import HarnessMonitorKit

extension TaskBoardOverviewView {
  var taskBoardCommandFocus: TaskBoardCommandFocus? {
    guard isCommandFocusActive else { return nil }
    let selectedIDs = selectionModelValue.orderedSelectedIDs
    return TaskBoardCommandFocus(
      selection: TaskBoardSelectionFocus(
        selectionCount: selectedIDs.count,
        canDelete: canDeleteTaskBoardCards(selectedIDs),
        canOpen: canOpenTaskBoardCard(selectedIDs),
        canOpenSpawnedTask: canOpenSpawnedTaskBoardCard(selectedIDs),
        dispatcher: taskBoardSelectionDispatcherValue
      ),
      operationsInspector: operationsInspectorFocus
    )
  }

  func canDeleteTaskBoardCards(_ selectedIDs: [TaskBoardCardID]) -> Bool {
    guard
      !selectedIDs.isEmpty,
      !isActionInFlight,
      selectionModelValue.selectedItemID == nil,
      selectionModelValue.acceptsBoardShortcuts,
      actions.canDeleteTargets
    else {
      return false
    }
    return deletionTargets(for: selectedIDs).count == selectedIDs.count
  }

  func requestDeleteSelectedTaskBoardCards() {
    let selectedIDs = selectionModelValue.orderedSelectedIDs
    guard canDeleteTaskBoardCards(selectedIDs) else {
      return
    }
    actions.deleteTaskBoardTargets(deletionTargets(for: selectedIDs))
  }

  func canOpenTaskBoardCard(_ selectedIDs: [TaskBoardCardID]) -> Bool {
    guard
      selectedIDs.count == 1,
      selectionModelValue.selectedItemID == nil,
      selectionModelValue.acceptsBoardShortcuts,
      let cardID = selectedIDs.first
    else {
      return false
    }
    return canOpenCard(cardID)
  }

  func canOpenSpawnedTaskBoardCard(_ selectedIDs: [TaskBoardCardID]) -> Bool {
    guard
      canOpenTaskBoardCard(selectedIDs),
      let cardID = selectedIDs.first
    else {
      return false
    }
    return canOpenSpawnedAgent(cardID)
  }

  func requestOpenSelectedTaskBoardCard() {
    let selectedIDs = selectionModelValue.orderedSelectedIDs
    guard canOpenTaskBoardCard(selectedIDs), let cardID = selectedIDs.first else {
      return
    }
    openCard(cardID)
  }

  func requestOpenSelectedSpawnedTask() {
    let selectedIDs = selectionModelValue.orderedSelectedIDs
    guard canOpenSpawnedTaskBoardCard(selectedIDs), let cardID = selectedIDs.first else {
      return
    }
    openSpawnedAgent(cardID)
  }

  func handleTaskBoardSelectionRequest(_ request: TaskBoardSelectionRequest?) {
    switch request {
    case .delete:
      requestDeleteSelectedTaskBoardCards()
    case .open:
      requestOpenSelectedTaskBoardCard()
    case .openSpawnedTask:
      requestOpenSelectedSpawnedTask()
    case nil:
      break
    }
  }
}
