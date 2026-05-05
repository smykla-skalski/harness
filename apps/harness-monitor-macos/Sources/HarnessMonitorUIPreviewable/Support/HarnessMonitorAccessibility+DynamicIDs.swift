import SwiftUI

extension HarnessMonitorAccessibility {
  public static func sessionRow(_ sessionID: String) -> String {
    "harness.sidebar.session.\(sessionID)"
  }

  public static func sessionRowFrame(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).frame"
  }

  public static func sessionRowSelectionFrame(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).selection.frame"
  }

  public static func sessionRowAgentStat(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).stat.agent"
  }

  public static func sessionRowTaskStat(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).stat.task"
  }

  public static func sessionRowStatsFrame(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).stats.frame"
  }

  public static func sessionRowLastActivityFrame(_ sessionID: String) -> String {
    "\(sessionRow(sessionID)).last-activity.frame"
  }

  public static func dashboardSessionCard(_ sessionID: String) -> String {
    "harness.board.session.\(slug(sessionID))"
  }

  public static func dashboardSessionCardFrame(_ sessionID: String) -> String {
    "\(dashboardSessionCard(sessionID)).frame"
  }

  public static func projectHeader(_ projectID: String) -> String {
    "harness.sidebar.project-header.\(slug(projectID))"
  }

  public static func projectHeaderFrame(_ projectID: String) -> String {
    "\(projectHeader(projectID)).frame"
  }

  public static func worktreeHeader(_ checkoutID: String) -> String {
    "harness.sidebar.worktree-header.\(slug(checkoutID))"
  }

  public static func worktreeHeaderFrame(_ checkoutID: String) -> String {
    "\(worktreeHeader(checkoutID)).frame"
  }

  public static func worktreeHeaderGlyph(_ checkoutID: String) -> String {
    "\(worktreeHeader(checkoutID)).glyph"
  }

  public static func sessionFilterButton(_ filter: String) -> String {
    "harness.sidebar.filter.\(filter)"
  }

  public static func sessionTaskCard(_ taskID: String) -> String {
    "harness.session.task.\(slug(taskID))"
  }

  public static func sessionAgentCard(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID))"
  }

  public static let sessionCockpitScrollView = "harness.session.cockpit.scroll"
  public static let sessionTaskListState = "harness.session.tasks.state"
  public static let sessionAgentListState = "harness.session.agents.state"

  public static func sessionAgentTaskDropFeedback(_ agentID: String) -> String {
    "\(sessionAgentCard(agentID)).task-drop-feedback"
  }

  public static func sessionAgentTuiMarker(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID)).tui-marker"
  }

  public static func sessionAgentSignalTrigger(_ agentID: String) -> String {
    "harness.session.agent.\(slug(agentID)).signal-trigger"
  }

  public static func agentRowPersonaChip(_ agentID: String) -> String {
    "\(sessionAgentCard(agentID)).persona"
  }

  public static func sessionSignalCard(_ signalID: String) -> String {
    "harness.session.signal.\(slug(signalID))"
  }

  public static func sessionEmptyState(_ section: String) -> String {
    "harness.session.empty-state.\(slug(section))"
  }

  public static func codexApprovalButton(_ approvalID: String, decision: String) -> String {
    "harness.window.workspace.codex.approval.\(slug(approvalID)).\(slug(decision))"
  }

  public static func agentTuiTab(_ tuiID: String) -> String {
    "harness.sheet.agent-tui.tab.\(slug(tuiID))"
  }

  public static func agentTuiKeyButton(_ key: String) -> String {
    "harness.sheet.agent-tui.key.\(slug(key))"
  }

  public static func sessionTimelinePaginationPageButton(_ pageNumber: Int) -> String {
    "harness.session.timeline.pagination.page.\(pageNumber)"
  }

  public static func sessionTimelineNode(_ key: String) -> String {
    "harness.session.timeline.node.\(slug(key))"
  }

  public static func sessionTimelineActionButton(decisionID: String, actionID: String) -> String {
    "harness.session.timeline.action.\(slug(decisionID)).\(slug(actionID))"
  }

  public static func preferencesMetricCard(_ key: String) -> String {
    "harness.preferences.metric.\(slug(key))"
  }
}
