extension HarnessMonitorAccessibility {
  public static let agentsWindow = "harness.agents.window"
  public static let agentsWindowDetailCard = "harness.agents.detail-card"
  public static let agentsWindowDetailSignalCommand = "harness.agents.detail.signal-command"
  public static let agentsWindowDetailSignalMessage = "harness.agents.detail.signal-message"
  public static let agentsWindowDetailSignalAction = "harness.agents.detail.signal-action"
  public static let agentsWindowDetailSignalSend = "harness.agents.detail.signal-send"
  public static let agentsWindowDetailPersona = "harness.agents.detail.persona"
  public static let agentsWindowDetailAssignedTasks = "harness.agents.detail.assigned-tasks"
  public static let agentsWindowDetailTimeline = "harness.agents.detail.timeline"
  public static let agentsWindowDetailRolePicker = "harness.agents.detail.role-picker"
  public static let agentsWindowDetailRoleChange = "harness.agents.detail.role-change"
  public static let agentsWindowDetailRoleRemove = "harness.agents.detail.role-remove"

  public static func agentTuiExternalTab(_ agentID: String) -> String {
    "harness.sheet.agent-tui.external-tab.\(slug(agentID))"
  }
}
