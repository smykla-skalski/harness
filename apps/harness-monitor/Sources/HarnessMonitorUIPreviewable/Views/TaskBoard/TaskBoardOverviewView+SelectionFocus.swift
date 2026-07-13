import HarnessMonitorKit

extension TaskBoardOverviewView {
  var taskBoardCommandFocus: TaskBoardCommandFocus? {
    guard isCommandFocusActive else { return nil }
    return TaskBoardCommandFocus(
      selection: taskBoardSelectionFocus,
      operationsInspector: operationsInspectorFocus
    )
  }

  var taskBoardSelectionFocus: TaskBoardSelectionFocus {
    TaskBoardSelectionFocus(
      selectionCount: orderedSelectedCardIDs.count,
      canDelete: canDeleteSelectedTaskBoardCards,
      dispatcher: taskBoardSelectionDispatcherValue
    )
  }

  private var canDeleteSelectedTaskBoardCards: Bool {
    canDeleteTaskBoardCards(orderedSelectedCardIDs)
  }

  func canDeleteTaskBoardCards(_ selectedIDs: [TaskBoardCardID]) -> Bool {
    guard
      !selectedIDs.isEmpty,
      !isActionInFlight,
      selectedTaskBoardItemIDValue == nil,
      !isCreatingTaskBoardItemValue,
      onDeleteTaskBoardTargets != nil,
      deletionTargets(for: selectedIDs).count == selectedIDs.count
    else {
      return false
    }
    guard let store else {
      return true
    }
    return !store.isBusy && !store.isSessionReadOnly && store.apiClient != nil
  }

  func requestDeleteSelectedTaskBoardCards() {
    guard canDeleteSelectedTaskBoardCards else {
      return
    }
    onDeleteTaskBoardTargets?(deletionTargets(for: orderedSelectedCardIDs))
  }
}
