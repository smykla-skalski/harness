import Foundation
import HarnessMonitorKit

enum OpenAnythingSessionRouteTarget: Equatable, Sendable {
  case agent(sessionID: String, agentID: String)
  case task(sessionID: String, taskID: String)
  case decision(sessionID: String, decisionID: String, resetDecisionFilters: Bool)
}

enum OpenAnythingRoutingStep: Equatable, Sendable {
  case presentNewSessionSheet
  case presentNewTaskSheet
  case attachExternalSession
  case refresh
  case refreshDiagnostics
  case reconnectDaemon
  case copyDiagnostics
  case openWindow(OpenAnythingWindowTarget)
  case openDashboard(OpenAnythingDashboardRoute)
  case openSettings(rawValue: String)
  case openSessionWindow(sessionID: String)
  case requestSessionRoute(OpenAnythingSessionRouteTarget)
  case selectSupervisorDecision(id: String)
  case selectDashboardDependency(pullRequestID: String)
}

enum OpenAnythingRouteExecutor {
  static func steps(
    for hit: OpenAnythingHit,
    showsPolicyCanvasLab: Bool
  ) -> [OpenAnythingRoutingStep] {
    steps(for: hit.target, showsPolicyCanvasLab: showsPolicyCanvasLab)
  }

  static func steps(
    for target: OpenAnythingTarget,
    showsPolicyCanvasLab: Bool
  ) -> [OpenAnythingRoutingStep] {
    switch target {
    case .action(let action):
      return actionSteps(action, showsPolicyCanvasLab: showsPolicyCanvasLab)
    case .window(let window):
      return window == .policyCanvasLab && !showsPolicyCanvasLab ? [] : [.openWindow(window)]
    case .dashboardRoute(let route):
      return [.openDashboard(route)]
    case .settingsSection(let rawValue):
      return [.openSettings(rawValue: rawValue)]
    case .session(let sessionID):
      return [.openSessionWindow(sessionID: sessionID)]
    case .taskBoardItem(_, let sessionID, let workItemID):
      return taskBoardSteps(sessionID: sessionID, workItemID: workItemID)
    case .decision(let id, let sessionID):
      return decisionSteps(id: id, sessionID: sessionID)
    case .dependency(let pullRequestID):
      return [
        .selectDashboardDependency(pullRequestID: pullRequestID),
        .openDashboard(.dependencies),
      ]
    case .loadedSession(let target):
      return loadedSessionSteps(target)
    }
  }

  private static func actionSteps(
    _ action: OpenAnythingAction,
    showsPolicyCanvasLab: Bool
  ) -> [OpenAnythingRoutingStep] {
    if action == .policyCanvasLab {
      return showsPolicyCanvasLab ? [.openWindow(.policyCanvasLab)] : []
    }
    return baseActionSteps[action] ?? []
  }

  private static let baseActionSteps: [OpenAnythingAction: [OpenAnythingRoutingStep]] = [
    .newSession: [.presentNewSessionSheet],
    .newTask: [.presentNewTaskSheet],
    .attachExternalSession: [.attachExternalSession],
    .openDashboard: [.openWindow(.dashboard)],
    .openTaskBoard: [.openDashboard(.taskBoard)],
    .openDependencies: [.openDashboard(.dependencies)],
    .openNotifications: [.openDashboard(.notifications)],
    .openPolicyCanvas: [.openDashboard(.policyCanvas)],
    .openDiagnostics: [.openDashboard(.diagnostics)],
    .refresh: [.refresh],
    .refreshDiagnostics: [.openDashboard(.diagnostics), .refreshDiagnostics],
    .reconnectDaemon: [.reconnectDaemon],
    .copyDiagnostics: [.copyDiagnostics],
    .settings: [.openWindow(.settings)],
    .openMCPSettings: [.openSettings(rawValue: "mcp")],
    .openDatabaseSettings: [.openSettings(rawValue: "database")],
  ]

  private static func taskBoardSteps(
    sessionID: String?,
    workItemID: String?
  ) -> [OpenAnythingRoutingStep] {
    guard let sessionID, let workItemID else {
      return [.openDashboard(.taskBoard)]
    }
    return [
      .requestSessionRoute(.task(sessionID: sessionID, taskID: workItemID)),
      .openSessionWindow(sessionID: sessionID),
    ]
  }

  private static func decisionSteps(
    id: String,
    sessionID: String?
  ) -> [OpenAnythingRoutingStep] {
    guard let sessionID else {
      return [
        .selectSupervisorDecision(id: id),
        .openDashboard(.taskBoard),
      ]
    }
    return [
      .requestSessionRoute(
        .decision(sessionID: sessionID, decisionID: id, resetDecisionFilters: true)
      ),
      .openSessionWindow(sessionID: sessionID),
    ]
  }

  private static func loadedSessionSteps(
    _ target: OpenAnythingLoadedSessionTarget
  ) -> [OpenAnythingRoutingStep] {
    switch target {
    case .agent(let sessionID, let agentID):
      return [
        .requestSessionRoute(.agent(sessionID: sessionID, agentID: agentID)),
        .openSessionWindow(sessionID: sessionID),
      ]
    case .task(let sessionID, let taskID):
      return [
        .requestSessionRoute(.task(sessionID: sessionID, taskID: taskID)),
        .openSessionWindow(sessionID: sessionID),
      ]
    case .timeline(let sessionID, _):
      return [.openSessionWindow(sessionID: sessionID)]
    }
  }
}
