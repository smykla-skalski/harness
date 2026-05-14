import HarnessMonitorKit
import SwiftUI

struct SessionsBoardView: View {
  let store: HarnessMonitorStore
  let sessionCatalog: HarnessMonitorStore.SessionCatalogSlice
  let dashboardUI: HarnessMonitorStore.ContentDashboardSlice

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
          snapshot: TaskBoardInboxSnapshot(
            generatedAt: nil,
            isFromCache: false
          ),
          taskBoardItems: dashboardUI.taskBoardItems,
          orchestratorStatus: dashboardUI.taskBoardOrchestratorStatus,
          evaluationSummary: dashboardUI.taskBoardEvaluationSummary,
          decisions: store.supervisorOpenDecisions,
          isActionInFlight: dashboardUI.isBusy,
          onOpenTaskBoardItem: openTaskBoardItem,
          onOpenDecision: openDecision,
          onEvaluateTaskBoard: evaluateTaskBoard,
          onRefreshTaskBoard: refreshTaskBoard
        )
        SessionsBoardRecentSessionsSection(
          store: store,
          sessions: sessionCatalog.recentSessions
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
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
  }

  private func openTaskBoardItem(_ item: TaskBoardItem) {
    guard let sessionID = item.sessionId else {
      return
    }
    Task { @MainActor in
      await store.selectSession(sessionID)
      if let workItemID = item.workItemId {
        store.presentedSheet = .taskActions(sessionID: sessionID, taskID: workItemID)
      }
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

  private func refreshTaskBoard() {
    Task { @MainActor in
      await store.refreshTaskBoardDashboard()
    }
  }

}
