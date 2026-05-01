extension HarnessMonitorAccessibility {
  public static let workspaceWindow = "harness.workspace.window"
  public static let workspaceDetailCard = "harness.workspace.detail-card"
  public static let workspaceDetailAwaitingDecisionState =
    "harness.workspace.detail.awaiting-decision.state"
  public static let workspaceDetailSignalCommand = "harness.workspace.detail.signal-command"
  public static let workspaceDetailSignalMessage = "harness.workspace.detail.signal-message"
  public static let workspaceDetailSignalAction = "harness.workspace.detail.signal-action"
  public static let workspaceDetailSignalSend = "harness.workspace.detail.signal-send"
  public static let workspaceDetailPersona = "harness.workspace.detail.persona"
  public static let workspaceDetailAssignedTasks = "harness.workspace.detail.assigned-tasks"
  public static let workspaceDetailTimeline = "harness.workspace.detail.timeline"
  public static let workspaceDetailRolePicker = "harness.workspace.detail.role-picker"
  public static let workspaceDetailRoleChange = "harness.workspace.detail.role-change"
  public static let workspaceDetailRoleRemove = "harness.workspace.detail.role-remove"

  public static func agentTuiExternalTab(_ agentID: String) -> String {
    "harness.sheet.agent-tui.external-tab.\(slug(agentID))"
  }

  public static func agentPendingDecisionBadge(_ agentID: String) -> String {
    "harness.sheet.agent-tui.pending-decision-badge.\(slug(agentID))"
  }

  public static func agentDetailAwaitingDecisionStrip(_ agentID: String) -> String {
    "harness.workspace.detail.awaiting-decision.\(slug(agentID))"
  }

  public static func agentDetailOpenDecisionsButton(_ agentID: String) -> String {
    "harness.workspace.detail.awaiting-decision.open.\(slug(agentID))"
  }

  public static func agentRuntimeStrip(_ agentID: String) -> String {
    "harness.workspace.detail.runtime.strip.\(slug(agentID))"
  }

  public static func agentRuntimeWatchdog(_ agentID: String) -> String {
    "harness.workspace.detail.runtime.watchdog.\(slug(agentID))"
  }

  public static func agentRuntimePendingPermissions(_ agentID: String) -> String {
    "harness.workspace.detail.runtime.pending-permissions.\(slug(agentID))"
  }

  public static func agentRuntimeDeadline(_ agentID: String) -> String {
    "harness.workspace.detail.runtime.deadline.\(slug(agentID))"
  }

  public static func agentRuntimeDisclosure(_ agentID: String) -> String {
    "harness.workspace.detail.runtime.disclosure.\(slug(agentID))"
  }

  public static func agentRuntimeDisclosureContent(_ agentID: String) -> String {
    "harness.workspace.detail.runtime.disclosure-content.\(slug(agentID))"
  }
}
