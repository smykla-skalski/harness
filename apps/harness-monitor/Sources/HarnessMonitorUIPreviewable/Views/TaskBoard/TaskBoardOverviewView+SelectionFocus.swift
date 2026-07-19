import HarnessMonitorKit

extension TaskBoardOverviewView {
  var taskBoardCommandFocus: TaskBoardCommandFocus? {
    guard isCommandFocusActive else { return nil }
    let selectedIDs = selectionModelValue.orderedSelectedIDs
    return TaskBoardCommandFocus(
      selection: TaskBoardSelectionFocus(
        selectionCount: selectedIDs.count,
        canDelete: canDeleteTaskBoardCards(selectedIDs),
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
      !selectionModelValue.isCreatingItem,
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
}
