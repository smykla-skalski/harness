import HarnessMonitorIntents
import HarnessMonitorKit
import SwiftUI

struct TaskBoardOverviewHost: View {
  typealias Scope = TaskBoardOverviewActions.Scope

  let scope: Scope
  let store: HarnessMonitorStore
  let navigationHistory: GlobalWindowNavigationHistory?
  let snapshot: TaskBoardInboxSnapshot
  let taskBoardItems: [TaskBoardItem]
  let decisions: [Decision]
  let orchestratorStatus: TaskBoardOrchestratorStatus?
  let evaluationSummary: TaskBoardEvaluationSummary?
  let isActionInFlight: Bool
  let isRouteVisible: Bool
  let showsOperationsPanel: Bool
  let isCommandFocusActive: Bool
  let operationsInspectorFocus: TaskBoardOperationsInspectorFocus?

  init(
    scope: Scope,
    store: HarnessMonitorStore,
    navigationHistory: GlobalWindowNavigationHistory? = nil,
    snapshot: TaskBoardInboxSnapshot,
    taskBoardItems: [TaskBoardItem],
    decisions: [Decision],
    orchestratorStatus: TaskBoardOrchestratorStatus?,
    evaluationSummary: TaskBoardEvaluationSummary?,
    isActionInFlight: Bool,
    isRouteVisible: Bool = true,
    showsOperationsPanel: Bool = true,
    isCommandFocusActive: Bool = true,
    operationsInspectorFocus: TaskBoardOperationsInspectorFocus? = nil
  ) {
    self.scope = scope
    self.store = store
    self.navigationHistory = navigationHistory
    self.snapshot = snapshot
    self.taskBoardItems = taskBoardItems
    self.decisions = decisions
    self.orchestratorStatus = orchestratorStatus
    self.evaluationSummary = evaluationSummary
    self.isActionInFlight = isActionInFlight
    self.isRouteVisible = isRouteVisible
    self.showsOperationsPanel = showsOperationsPanel
    self.isCommandFocusActive = isCommandFocusActive
    self.operationsInspectorFocus = operationsInspectorFocus
  }

  var body: some View {
    TaskBoardOverviewView(
      snapshot: snapshot,
      taskBoardItems: taskBoardItems,
      store: store,
      navigationHistory: navigationHistory,
      orchestratorStatus: orchestratorStatus,
      evaluationSummary: scope.isDashboard ? evaluationSummary : nil,
      taskBoardSessionID: scope.sessionID,
      isRouteVisible: isRouteVisible,
      contentHorizontalPadding: scope.taskBoardContentHorizontalPadding,
      fillsAvailableHeight: scope.fillsAvailableHeight,
      showsOperationsPanel: scope.isDashboard && showsOperationsPanel,
      isCommandFocusActive: isCommandFocusActive,
      operationsInspectorFocus: operationsInspectorFocus,
      decisions: decisions,
      isActionInFlight: isActionInFlight,
      actions: TaskBoardOverviewActions(store: store, scope: scope),
      decisionItems: store.supervisorOpenDecisionPresentationItems,
      decisionsByID: store.supervisorOpenDecisionsByID
    )
  }
}

extension TaskBoardOverviewHost.Scope {
  fileprivate var isDashboard: Bool {
    self == .dashboard
  }

  fileprivate var sessionID: String? {
    switch self {
    case .dashboard:
      nil
    case .session(let sessionID):
      sessionID
    }
  }

  fileprivate var taskBoardContentHorizontalPadding: CGFloat {
    switch self {
    case .dashboard:
      24
    case .session:
      0
    }
  }

  fileprivate var fillsAvailableHeight: Bool {
    switch self {
    case .dashboard:
      true
    case .session:
      false
    }
  }
}
