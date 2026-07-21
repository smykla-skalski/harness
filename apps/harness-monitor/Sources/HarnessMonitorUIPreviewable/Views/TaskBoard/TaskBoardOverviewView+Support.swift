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
    guard let selectedItemID = selectionModelValue.selectedItemID else { return nil }
    return currentPresentation.taskBoardItem(id: selectedItemID)
      ?? taskBoardItems.first { $0.id == selectedItemID }
  }

  var taskBoardManagementSheet: Binding<TaskBoardManagementSheet?> {
    Binding(
      get: {
        if selectionModelValue.isCreatingItem {
          return .create
        }
        guard
          let selectedItemID = selectionModelValue.selectedItemID,
          selectedTaskBoardItem != nil
        else {
          return nil
        }
        return .edit(itemID: selectedItemID)
      },
      set: { sheet in
        if sheet == nil {
          selectionModelValue.clearSelectedItem()
        }
      }
    )
  }

  func taskBoardManagementSheetContent(_ sheet: TaskBoardManagementSheet) -> some View {
    let item = taskBoardManagementItem(for: sheet)
    return ScrollView {
      TaskBoardItemManagementPanel(
        item: item,
        metrics: metrics,
        isActionInFlight: isActionInFlight,
        runOnceDryRun: runOnceDryRun,
        evaluateDryRun: evaluateDryRun,
        actions: actions,
        evaluatePreviewState: evaluatePreviewStateValue,
        selectionModel: selectionModelValue,
        backlink: taskBoardParentBacklink(for: item),
        childrenSummary: taskBoardChildrenSummary(for: item)
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

  /// The umbrella/children relationship spans every project and repository,
  /// so it must resolve from the store's full item pool - never from
  /// `taskBoardItems`, which can be scoped to one session when this view is
  /// embedded there.
  var allKnownTaskBoardItems: [TaskBoardItem] {
    store?.globalTaskBoardItems ?? taskBoardItems
  }

  private func taskBoardParentBacklink(for item: TaskBoardItem?) -> TaskBoardParentBacklink {
    guard let item else { return .none }
    return TaskBoardParentBacklink(item: item, loadedItems: allKnownTaskBoardItems)
  }

  private func taskBoardChildrenSummary(
    for item: TaskBoardItem?
  ) -> TaskBoardUmbrellaChildrenSummary? {
    guard let item, item.kind == .umbrella else { return nil }
    return TaskBoardUmbrellaChildrenSummary.summarizing(
      item.id, in: allKnownTaskBoardItems, collapsedLanes: collapsedLanesValue
    )
  }

  func moveTaskBoardItem(_ itemID: String, to lane: TaskBoardInboxLane) -> Bool {
    guard actions.canMoveTaskBoardItems else {
      return false
    }
    guard
      let item = currentPresentation.taskBoardItem(id: itemID)
        ?? taskBoardItems.first(where: { $0.id == itemID }),
      let currentLane = TaskBoardInboxLane(taskBoardItem: item),
      currentLane != lane,
      let dropStatus = lane.taskBoardDropStatus(for: item)
    else {
      return false
    }
    actions.moveTaskBoardItems([
      TaskBoardItemStatusUpdate(id: itemID, status: dropStatus)
    ])
    return true
  }

  func moveInboxItem(
    sessionID: String,
    taskID: String,
    to lane: TaskBoardInboxLane
  ) -> Bool {
    guard
      actions.canMoveInboxItems,
      let status = lane.taskDropStatus,
      let item = snapshot.items.first(where: {
        $0.session.sessionId == sessionID && $0.task.taskId == taskID
      }),
      item.lane != lane
    else {
      return false
    }
    actions.moveInboxItems([
      TaskBoardInboxStatusUpdate(
        sessionID: item.session.sessionId,
        taskID: item.task.taskId,
        status: status
      )
    ])
    return true
  }

  func startTaskBoardItemCreation() {
    selectionModelValue.beginCreatingItem()
  }

  func runOrchestratorOnce() {
    requestRunOnce(TaskBoardOrchestratorRunOnceRequest(dryRun: runOnceDryRun))
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
