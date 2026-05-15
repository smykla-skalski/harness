import HarnessMonitorKit
import SwiftUI

extension SessionWindowOverview {
  var taskBoardSnapshot: TaskBoardInboxSnapshot {
    guard let detail = snapshot.detail else {
      return TaskBoardInboxSnapshot(
        generatedAt: nil,
        isFromCache: snapshot.source != .live
      )
    }
    return TaskBoardInboxSnapshot(
      sessions: [snapshot.summary],
      detailsBySessionID: [snapshot.summary.sessionId: detail],
      generatedAt: nil,
      isFromCache: snapshot.source != .live
    )
  }

  var linkedTaskBoardItems: [TaskBoardItem] {
    let dashboardItems = store.contentUI.dashboard.taskBoardItems
    let sourceItems = dashboardItems.isEmpty ? snapshot.taskBoardItems ?? [] : dashboardItems
    return sourceItems.filter { item in
      item.sessionId == snapshot.summary.sessionId
    }
  }

  func openTaskActions(_ item: TaskBoardInboxItem) {
    store.presentedSheet = .taskActions(
      sessionID: item.session.sessionId,
      taskID: item.task.taskId
    )
  }

  func openTaskBoardItem(_ item: TaskBoardItem) {
    guard let workItemId = item.workItemId else {
      return
    }
    store.presentedSheet = .taskActions(
      sessionID: snapshot.summary.sessionId,
      taskID: workItemId
    )
  }

  func moveTaskBoardItem(_ itemID: String, status: TaskBoardStatus) {
    Task { @MainActor in
      await store.updateTaskBoardItemStatus(id: itemID, status: status)
    }
  }

  func createTaskBoardItem(
    _ request: TaskBoardCreateItemRequest,
    initialStatus: TaskBoardStatus
  ) {
    Task { @MainActor in
      await store.createTaskBoardItem(request: request, initialStatus: initialStatus)
    }
  }

  func updateTaskBoardItem(_ itemID: String, request: TaskBoardUpdateItemRequest) {
    Task { @MainActor in
      await store.updateTaskBoardItem(id: itemID, request: request)
    }
  }

  func deleteTaskBoardItem(_ item: TaskBoardItem) {
    Task { @MainActor in
      await store.deleteTaskBoardItem(id: item.id)
    }
  }

  func moveInboxItem(_ item: TaskBoardInboxItem, status: TaskStatus) {
    Task { @MainActor in
      await store.updateTaskStatus(
        taskID: item.task.taskId,
        status: status,
        sessionID: item.session.sessionId
      )
    }
  }

  func openDecision(_ decision: Decision) {
    store.supervisorSelectedDecisionID = decision.id
    store.requestSessionRoute(
      .decision(
        sessionID: decision.sessionID ?? snapshot.summary.sessionId,
        decisionID: decision.id
      ),
      resetDecisionFilters: true
    )
  }

  func evaluateTaskBoard() {
    Task { @MainActor in
      await store.evaluateTaskBoard()
    }
  }

  func evaluateTaskBoardItem(_ item: TaskBoardItem) {
    Task { @MainActor in
      await store.evaluateTaskBoard(status: item.status, itemID: item.id)
    }
  }

  func refreshTaskBoard() {
    Task { @MainActor in
      await store.refreshTaskBoardDashboard()
    }
  }

  func startTaskBoardOrchestrator() {
    Task { @MainActor in
      await store.startTaskBoardOrchestrator()
    }
  }

  func stopTaskBoardOrchestrator() {
    Task { @MainActor in
      await store.stopTaskBoardOrchestrator()
    }
  }

  func runTaskBoardOrchestratorOnce(_ request: TaskBoardOrchestratorRunOnceRequest) {
    Task { @MainActor in
      await store.runTaskBoardOrchestratorOnce(request: request)
    }
  }
}
