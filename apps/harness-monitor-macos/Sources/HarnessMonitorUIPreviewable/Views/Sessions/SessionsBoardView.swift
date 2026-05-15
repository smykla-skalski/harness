import HarnessMonitorKit
import SwiftUI

struct SessionsBoardView: View {
  let store: HarnessMonitorStore
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  @State private var selectedSurface: SessionsBoardSurface = .taskBoard
  @State private var taskBoardInboxSnapshot = TaskBoardInboxSnapshot(
    generatedAt: nil,
    isFromCache: true
  )

  init(
    store: HarnessMonitorStore,
    sessionCatalog: HarnessMonitorStore.SessionCatalogSlice,
    dashboardUI: HarnessMonitorStore.ContentDashboardSlice
  ) {
    self.store = store
    self.sessionCatalog = sessionCatalog
    self.dashboardUI = dashboardUI
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("Dashboard surface", selection: $selectedSurface) {
        ForEach(SessionsBoardSurface.allCases) { surface in
          Text(surface.title).tag(surface)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 300)
      .padding(.horizontal, 24)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, alignment: .leading)

      switch selectedSurface {
      case .taskBoard:
        taskBoardSurface
      case .policyCanvas:
        PolicyCanvasView(store: store, dashboardUI: dashboardUI)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(HarnessMonitorAccessibility.sessionsBoardRoot)
    .task {
      HarnessMonitorUITestTrace.record(
        component: "sessions.board",
        event: "mounted",
        details: [
          "recent_session_count": String(sessionCatalog.recentSessions.count),
          "selected_session_id": store.selectedSessionID ?? "nil",
        ]
      )
    }
    .task(id: taskBoardInboxSessionIDs) {
      await refreshVisibleTaskBoardInboxSnapshot()
    }
  }

  private var visibleTaskBoardSessions: [SessionSummary] {
    let visible = store.visibleSessions
    return visible.isEmpty ? sessionCatalog.recentSessions : visible
  }

  private var taskBoardInboxSessionIDs: [String] {
    visibleTaskBoardSessions.map(\.sessionId)
  }

  private func refreshVisibleTaskBoardInboxSnapshot() async {
    let snapshot = await store.loadCachedTaskBoardInboxSnapshot(
      sessions: visibleTaskBoardSessions,
      limit: 120
    )
    guard !Task.isCancelled else { return }
    taskBoardInboxSnapshot = snapshot
  }

  private var taskBoardSurface: some View {
    HarnessMonitorColumnScrollView(
      horizontalPadding: 24,
      verticalPadding: 24,
      constrainContentWidth: true,
      readableWidth: false,
      topScrollEdgeEffect: .soft,
      scrollSurfaceIdentifier: HarnessMonitorAccessibility.sessionsBoardScrollView,
      scrollSurfaceLabel: "Sessions board"
    ) {
      VStack(alignment: .leading, spacing: 24) {
        TaskBoardOverviewView(
          snapshot: taskBoardInboxSnapshot,
          taskBoardItems: dashboardUI.taskBoardItems,
          orchestratorStatus: dashboardUI.taskBoardOrchestratorStatus,
          evaluationSummary: dashboardUI.taskBoardEvaluationSummary,
          decisions: store.supervisorOpenDecisions,
          isActionInFlight: dashboardUI.isBusy,
          onOpenItem: openInboxItem,
          onOpenTaskBoardItem: openTaskBoardItem,
          onMoveInboxItem: moveInboxItem,
          onMoveTaskBoardItem: moveTaskBoardItem,
          onOpenDecision: openDecision,
          onCreateTaskBoardItem: createTaskBoardItem,
          onUpdateTaskBoardItem: updateTaskBoardItem,
          onDeleteTaskBoardItem: deleteTaskBoardItem,
          onEvaluateTaskBoard: evaluateTaskBoard,
          onEvaluateTaskBoardItem: evaluateTaskBoardItem,
          onRefreshTaskBoard: refreshTaskBoard,
          onStartTaskBoardOrchestrator: startTaskBoardOrchestrator,
          onStopTaskBoardOrchestrator: stopTaskBoardOrchestrator,
          onRunTaskBoardOrchestratorOnce: runTaskBoardOrchestratorOnce
        )
        SessionsBoardRecentSessionsSection(
          store: store,
          sessions: sessionCatalog.recentSessions
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func openTaskBoardItem(_ item: TaskBoardItem) {
    guard let sessionID = item.sessionId else { return }
    Task { @MainActor in
      await store.selectSession(sessionID)
      if let workItemID = item.workItemId {
        store.presentedSheet = .taskActions(sessionID: sessionID, taskID: workItemID)
      }
    }
  }

  private func moveTaskBoardItem(_ itemID: String, status: TaskBoardStatus) {
    Task { @MainActor in
      await store.updateTaskBoardItemStatus(id: itemID, status: status)
    }
  }

  private func createTaskBoardItem(
    _ request: TaskBoardCreateItemRequest,
    initialStatus: TaskBoardStatus
  ) {
    Task { @MainActor in
      await store.createTaskBoardItem(request: request, initialStatus: initialStatus)
    }
  }

  private func updateTaskBoardItem(_ itemID: String, request: TaskBoardUpdateItemRequest) {
    Task { @MainActor in
      await store.updateTaskBoardItem(id: itemID, request: request)
    }
  }

  private func deleteTaskBoardItem(_ item: TaskBoardItem) {
    Task { @MainActor in
      await store.deleteTaskBoardItem(id: item.id)
    }
  }

  private func openInboxItem(_ item: TaskBoardInboxItem) {
    Task { @MainActor in
      await store.selectSession(item.session.sessionId)
      store.presentedSheet = .taskActions(
        sessionID: item.session.sessionId,
        taskID: item.task.taskId
      )
    }
  }

  private func moveInboxItem(_ item: TaskBoardInboxItem, status: TaskStatus) {
    Task { @MainActor in
      await store.updateTaskStatus(
        taskID: item.task.taskId,
        status: status,
        sessionID: item.session.sessionId
      )
    }
  }

  private func openDecision(_ decision: Decision) {
    store.supervisorSelectedDecisionID = decision.id
    guard let sessionID = decision.sessionID else {
      return
    }
    Task { @MainActor in
      await store.selectSession(sessionID)
    }
  }

  private func evaluateTaskBoard() {
    Task { @MainActor in
      await store.evaluateTaskBoard()
    }
  }

  private func evaluateTaskBoardItem(_ item: TaskBoardItem) {
    let request = TaskBoardOverviewItemBehavior.evaluationRequest(for: item)
    Task { @MainActor in
      await store.evaluateTaskBoard(request: request)
    }
  }

  private func refreshTaskBoard() {
    Task { @MainActor in
      await store.refreshTaskBoardDashboard()
    }
  }

  private func startTaskBoardOrchestrator() {
    Task { @MainActor in
      await store.startTaskBoardOrchestrator()
    }
  }

  private func stopTaskBoardOrchestrator() {
    Task { @MainActor in
      await store.stopTaskBoardOrchestrator()
    }
  }

  private func runTaskBoardOrchestratorOnce(_ request: TaskBoardOrchestratorRunOnceRequest) {
    Task { @MainActor in
      await store.runTaskBoardOrchestratorOnce(request: request)
    }
  }

}

private enum SessionsBoardSurface: String, CaseIterable, Identifiable {
  case taskBoard
  case policyCanvas

  var id: String { rawValue }

  var title: String {
    switch self {
    case .taskBoard:
      "Task Board"
    case .policyCanvas:
      "Policy Canvas"
    }
  }
}
