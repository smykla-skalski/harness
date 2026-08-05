import HarnessMonitorKit

extension TaskBoardOverviewView {
  func applyPendingDashboardTargetIfReady() async {
    guard
      isRouteVisible,
      let navigationHistory,
      let request = navigationHistory.pendingDashboardTaskBoardRestoreRequest
    else { return }
    if let resolvedTarget = await resolveDashboardTarget(request.target) {
      guard canCommitDashboardNavigation(request, history: navigationHistory) else { return }
      presentDashboardTarget(resolvedTarget)
      navigationHistory.finishDashboardTaskBoardRestoreRequest(request.requestID)
      return
    }
    guard canCommitDashboardNavigation(request, history: navigationHistory) else { return }
    let readiness = DashboardTaskBoardNavigationReadiness(
      taskBoardSnapshotAvailable: store?.contentUI.dashboard
        .taskBoardItemsSnapshotAvailable == true || !taskBoardItems.isEmpty,
      inboxSnapshotAvailable: snapshot.generatedAt != nil || !snapshot.items.isEmpty
    )
    guard readiness.canReportUnavailable(for: request.target) else { return }
    navigationHistory.finishDashboardTaskBoardRestoreRequest(request.requestID)
    store?.presentFailureFeedback("The requested task is unavailable")
  }

  private func resolveDashboardTarget(
    _ target: DashboardTaskBoardNavigationTarget
  ) async -> DashboardTaskBoardResolvedNavigationTarget? {
    switch target {
    case .item(let itemID):
      guard let item = taskBoardItems.first(where: { $0.id == itemID }) else { return nil }
      selectionModelValue.selectAPIItem(item)
      return .boardItem
    case .loadedSessionTask(let sessionID, let taskID):
      guard await actions.selectVerifiedSessionTask(sessionID: sessionID, taskID: taskID) else {
        return nil
      }
      return .sessionTask(sessionID: sessionID, taskID: taskID)
    case .sessionTask(let sessionID, let taskID):
      if let item = taskBoardItems.first(where: {
        $0.sessionId == sessionID && $0.workItemId == taskID
      }) {
        selectionModelValue.selectAPIItem(item)
        return .boardItem
      }
      guard
        let item = snapshot.items.first(where: {
          $0.session.sessionId == sessionID && $0.task.taskId == taskID
        })
      else { return nil }
      guard
        await actions.selectVerifiedSessionTask(
          sessionID: item.session.sessionId,
          taskID: item.task.taskId
        )
      else { return nil }
      return .sessionTask(sessionID: item.session.sessionId, taskID: item.task.taskId)
    }
  }

  private func presentDashboardTarget(_ target: DashboardTaskBoardResolvedNavigationTarget) {
    switch target {
    case .boardItem:
      return
    case .sessionTask(let sessionID, let taskID):
      actions.presentVerifiedSessionTask(sessionID: sessionID, taskID: taskID)
    }
  }

  private func canCommitDashboardNavigation(
    _ request: DashboardTaskBoardNavigationRestoreRequest,
    history: GlobalWindowNavigationHistory
  ) -> Bool {
    DashboardTaskBoardNavigationCommitGuard.canCommit(
      requestID: request.requestID,
      pendingRequestID: history.pendingDashboardTaskBoardRestoreRequest?.requestID,
      isRouteVisible: isRouteVisible,
      isCancelled: Task.isCancelled
    )
  }
}

enum DashboardTaskBoardResolvedNavigationTarget: Equatable {
  case boardItem
  case sessionTask(sessionID: String, taskID: String)
}

struct DashboardTaskBoardNavigationTaskID: Equatable {
  let requestID: Int?
  let isRouteVisible: Bool
  let presentationInput: TaskBoardOverviewPresentationInput
}

enum DashboardTaskBoardNavigationCommitGuard {
  static func canCommit(
    requestID: Int,
    pendingRequestID: Int?,
    isRouteVisible: Bool,
    isCancelled: Bool
  ) -> Bool {
    isRouteVisible && !isCancelled && requestID == pendingRequestID
  }
}

struct DashboardTaskBoardNavigationReadiness: Equatable {
  let taskBoardSnapshotAvailable: Bool
  let inboxSnapshotAvailable: Bool

  func canReportUnavailable(for target: DashboardTaskBoardNavigationTarget) -> Bool {
    switch target {
    case .item:
      taskBoardSnapshotAvailable
    case .sessionTask:
      taskBoardSnapshotAvailable && inboxSnapshotAvailable
    case .loadedSessionTask:
      true
    }
  }
}
