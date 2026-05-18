import HarnessMonitorKit
import SwiftUI

extension TaskBoardOverviewView {
  private var detailRowHorizontalPadding: CGFloat {
    contentHorizontalPadding
  }

  func taskBoardDetailRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .padding(.horizontal, detailRowHorizontalPadding)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  var hasRouteContent: Bool {
    !snapshot.isEmpty || !taskBoardItems.isEmpty || !decisions.isEmpty || orchestratorStatus != nil
      || evaluationSummary != nil
  }

  var selectedTaskBoardItem: TaskBoardItem? {
    guard let selectedTaskBoardItemIDValue else { return nil }
    return cachedPresentation.taskBoardItem(id: selectedTaskBoardItemIDValue)
      ?? taskBoardItems.first { $0.id == selectedTaskBoardItemIDValue }
  }

  func openTaskBoardItem(_ item: TaskBoardItem) {
    switch TaskBoardOverviewItemBehavior.selectionAction(for: item) {
    case .openLinkedTask:
      isCreatingTaskBoardItemValue = false
      selectedTaskBoardItemIDValue = nil
      onOpenTaskBoardItem(item)
    case .selectBoardItem:
      isCreatingTaskBoardItemValue = false
      selectedTaskBoardItemIDValue = item.id
    }
  }

  func moveTaskBoardItem(_ itemID: String, to lane: TaskBoardInboxLane) -> Bool {
    guard let onMoveTaskBoardItem else {
      return false
    }
    guard
      let item = cachedPresentation.taskBoardItem(id: itemID)
        ?? taskBoardItems.first(where: { $0.id == itemID }),
      let currentLane = TaskBoardInboxLane(status: item.status),
      currentLane != lane
    else {
      return false
    }
    onMoveTaskBoardItem(itemID, lane.taskBoardDropStatus(for: item))
    return true
  }

  func moveInboxItem(
    _ payload: TaskBoardInboxItemDragPayload,
    to lane: TaskBoardInboxLane
  ) -> Bool {
    guard
      let onMoveInboxItem,
      let status = lane.taskDropStatus,
      let item = snapshot.items.first(where: {
        $0.session.sessionId == payload.sessionID && $0.task.taskId == payload.taskID
      }),
      item.lane != lane
    else {
      return false
    }
    onMoveInboxItem(item, status)
    return true
  }

  func clearSelectedTaskBoardItem() {
    selectedTaskBoardItemIDValue = nil
    isCreatingTaskBoardItemValue = false
  }

  var selectionClearingDeleteAction: ((TaskBoardItem) -> Void)? {
    guard let delete = onDeleteTaskBoardItem else { return nil }
    return { item in
      if selectedTaskBoardItemIDValue == item.id {
        selectedTaskBoardItemIDValue = nil
      }
      delete(item)
    }
  }

  func startTaskBoardItemCreation() {
    selectedTaskBoardItemIDValue = nil
    isCreatingTaskBoardItemValue = true
  }

  func runOrchestratorOnce() {
    onRunTaskBoardOrchestratorOnce?(TaskBoardOrchestratorRunOnceRequest())
  }

  func runOrchestratorOnceForItem(_ item: TaskBoardItem) {
    onRunTaskBoardOrchestratorOnce?(TaskBoardOverviewItemBehavior.runOnceRequest(for: item))
  }

  var selectedTaskBoardItemEvaluateAction: ((TaskBoardItem) -> Void)? {
    guard onEvaluateTaskBoardItem != nil || onEvaluateTaskBoard != nil else {
      return nil
    }
    return evaluateSelectedTaskBoardItem
  }

  func evaluateSelectedTaskBoardItem(_ item: TaskBoardItem) {
    if let onEvaluateTaskBoardItem {
      onEvaluateTaskBoardItem(item)
    } else {
      onEvaluateTaskBoard?()
    }
    selectedTaskBoardItemIDValue = item.id
  }

}
