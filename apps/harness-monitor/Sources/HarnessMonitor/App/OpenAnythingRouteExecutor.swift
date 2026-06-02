import Foundation
import HarnessMonitorKit

/// Routing step plumbing for the Open Anything palette.
///
/// `OpenAnythingTarget` (in HarnessMonitorKit) is the *what* the user picked:
/// an action, a window, a dashboard route, a session, etc. `OpenAnythingRoutingStep`
/// is the *how* the host executes it: a flat ordered command stream the scene
/// host modifier walks one step at a time.
///
/// Some target shapes map 1-to-1 to a single step (`.window(.settings)` ->
/// `.openWindow(.settings)`, `.dashboardRoute(.reviews)` ->
/// `.openDashboard(.reviews)`). The executor preserves the indirection on
/// purpose: it lets the host modifier wrap a target's effect in multiple
/// command-flavoured steps (presentation, command, navigation) without
/// teaching the target enum about every host concern. Some targets fan out
/// to >1 step (review hits select then navigate, task-board items request a
/// session route then open the session window). Keep that overlap explicit
/// rather than collapsing it.
///
/// Deep-link steps (`.openExternalURL`, `.revealInFinder`) are not produced by
/// any current target. They are hooks for context-menu row actions in the
/// palette view: "Open in browser" on review URLs, "Reveal in Finder" on
/// session worktree paths. The host modifier dispatches them the same way as
/// any other command step.

enum OpenAnythingSessionRouteTarget: Equatable, Sendable {
  case agent(sessionID: String, agentID: String)
  case task(sessionID: String, taskID: String)
  case decision(sessionID: String, decisionID: String, resetDecisionFilters: Bool)
  case timeline(sessionID: String, entryID: String)
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
  case selectDashboardReview(pullRequestID: String)
  case openExternalURL(URL)
  case revealInFinder(URL)
}

private enum OpenAnythingActionRoutingGroup {
  case session
  case dashboard
  case maintenance
  case settings
}

enum OpenAnythingRouteExecutor {
  static func steps(for target: OpenAnythingTarget) -> [OpenAnythingRoutingStep] {
    switch target {
    case .action(let action):
      return actionSteps(action)
    case .window(let window):
      return [.openWindow(window)]
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
    case .review(let pullRequestID):
      return [
        .selectDashboardReview(pullRequestID: pullRequestID),
        .openDashboard(.reviews),
      ]
    case .loadedSession(let target):
      return loadedSessionSteps(target)
    }
  }

  // Exhaustive switch on every `OpenAnythingAction`. The compiler now refuses
  // to build if a new action is added without a steps mapping, closing the
  // silent no-op gap the old dictionary lookup left open.
  private static func actionSteps(_ action: OpenAnythingAction) -> [OpenAnythingRoutingStep] {
    return steps(forAction: action)
  }

  private static func steps(forAction action: OpenAnythingAction) -> [OpenAnythingRoutingStep] {
    switch routingGroup(for: action) {
    case .session:
      return sessionActionSteps(action)
    case .dashboard:
      return dashboardActionSteps(action)
    case .maintenance:
      return maintenanceActionSteps(action)
    case .settings:
      return settingsActionSteps(action)
    }
  }

  private static func routingGroup(for action: OpenAnythingAction)
    -> OpenAnythingActionRoutingGroup
  {
    switch action {
    case .newSession, .newTask, .attachExternalSession:
      return .session
    case .openDashboard, .openTaskBoard, .openReviews, .openAudit, .openNotifications,
      .openPolicyCanvas, .openDiagnostics, .openDebugging:
      return .dashboard
    case .refresh, .refreshDiagnostics, .reconnectDaemon, .copyDiagnostics:
      return .maintenance
    case .settings, .openMCPSettings, .openDatabaseSettings:
      return .settings
    }
  }

  private static func sessionActionSteps(
    _ action: OpenAnythingAction
  ) -> [OpenAnythingRoutingStep] {
    switch action {
    case .newSession:
      return [.presentNewSessionSheet]
    case .newTask:
      return [.presentNewTaskSheet]
    case .attachExternalSession:
      return [.attachExternalSession]
    default:
      return []
    }
  }

  private static func dashboardActionSteps(
    _ action: OpenAnythingAction
  ) -> [OpenAnythingRoutingStep] {
    switch action {
    case .openDashboard:
      return [.openWindow(.dashboard)]
    case .openTaskBoard:
      return [.openDashboard(.taskBoard)]
    case .openReviews:
      return [.openDashboard(.reviews)]
    case .openAudit, .openNotifications:
      return [.openDashboard(.audit)]
    case .openPolicyCanvas:
      return [.openDashboard(.policyCanvas)]
    case .openDiagnostics:
      return [.openDashboard(.diagnostics)]
    case .openDebugging:
      return [.openDashboard(.debugging)]
    default:
      return []
    }
  }

  private static func maintenanceActionSteps(
    _ action: OpenAnythingAction
  ) -> [OpenAnythingRoutingStep] {
    switch action {
    case .refresh:
      return [.refresh]
    case .refreshDiagnostics:
      return [.openDashboard(.diagnostics), .refreshDiagnostics]
    case .reconnectDaemon:
      return [.reconnectDaemon]
    case .copyDiagnostics:
      return [.copyDiagnostics]
    default:
      return []
    }
  }

  private static func settingsActionSteps(
    _ action: OpenAnythingAction
  ) -> [OpenAnythingRoutingStep] {
    switch action {
    case .settings:
      return [.openWindow(.settings)]
    case .openMCPSettings:
      return [.openSettings(rawValue: "mcp")]
    case .openDatabaseSettings:
      return [.openSettings(rawValue: "database")]
    default:
      return []
    }
  }

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
    case .timeline(let sessionID, let entryID):
      return [
        .requestSessionRoute(.timeline(sessionID: sessionID, entryID: entryID)),
        .openSessionWindow(sessionID: sessionID),
      ]
    }
  }
}
