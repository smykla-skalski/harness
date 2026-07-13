import HarnessMonitorKit
import SwiftUI

enum TaskBoardManagementSheet: Identifiable, Equatable {
  case create
  case edit(itemID: String)

  var id: String {
    switch self {
    case .create:
      "create"
    case .edit(let itemID):
      "edit:\(itemID)"
    }
  }
}

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
    return currentPresentation.taskBoardItem(id: selectedTaskBoardItemIDValue)
      ?? taskBoardItems.first { $0.id == selectedTaskBoardItemIDValue }
  }

  var taskBoardManagementSheet: Binding<TaskBoardManagementSheet?> {
    Binding(
      get: {
        if isCreatingTaskBoardItemValue {
          return .create
        }
        guard let selectedTaskBoardItemIDValue, selectedTaskBoardItem != nil else {
          return nil
        }
        return .edit(itemID: selectedTaskBoardItemIDValue)
      },
      set: { sheet in
        if sheet == nil {
          clearSelectedTaskBoardItem()
        }
      }
    )
  }

  func taskBoardManagementSheetContent(_ sheet: TaskBoardManagementSheet) -> some View {
    ScrollView {
      TaskBoardItemManagementPanel(
        item: taskBoardManagementItem(for: sheet),
        metrics: metrics,
        isActionInFlight: isActionInFlight,
        store: store,
        onCreate: onCreateTaskBoardItem,
        onUpdate: onUpdateTaskBoardItem,
        onDelete: selectionClearingDeleteAction,
        onRunOnce: runOrchestratorOnceForItem,
        onEvaluate: selectedTaskBoardItemEvaluateAction,
        onBeginPlan: onBeginTaskBoardPlan,
        onSubmitPlan: onSubmitTaskBoardPlan,
        onApprovePlan: onApproveTaskBoardPlan,
        onRevokePlan: onRevokeTaskBoardPlan,
        onRefresh: onRefreshTaskBoard,
        onClose: clearSelectedTaskBoardItem
      )
      .padding(HarnessMonitorTheme.spacingLG)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(
      minWidth: 1_120,
      idealWidth: 1_240,
      minHeight: 760,
      maxHeight: .infinity,
      alignment: .topLeading
    )
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
    guard let onMoveTaskBoardItems else {
      return false
    }
    guard
      let item = currentPresentation.taskBoardItem(id: itemID)
        ?? taskBoardItems.first(where: { $0.id == itemID }),
      let currentLane = TaskBoardInboxLane(status: item.status),
      currentLane != lane
    else {
      return false
    }
    onMoveTaskBoardItems([
      TaskBoardItemStatusUpdate(id: itemID, status: lane.taskBoardDropStatus(for: item))
    ])
    return true
  }

  func moveInboxItem(
    sessionID: String,
    taskID: String,
    to lane: TaskBoardInboxLane
  ) -> Bool {
    guard
      let onMoveInboxItems,
      let status = lane.taskDropStatus,
      let item = snapshot.items.first(where: {
        $0.session.sessionId == sessionID && $0.task.taskId == taskID
      }),
      item.lane != lane
    else {
      return false
    }
    onMoveInboxItems([
      TaskBoardInboxStatusUpdate(
        sessionID: item.session.sessionId,
        taskID: item.task.taskId,
        status: status
      )
    ])
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

  private func taskBoardManagementItem(for sheet: TaskBoardManagementSheet) -> TaskBoardItem? {
    switch sheet {
    case .create:
      nil
    case .edit(let itemID):
      currentPresentation.taskBoardItem(id: itemID)
        ?? taskBoardItems.first(where: { $0.id == itemID })
    }
  }

}
