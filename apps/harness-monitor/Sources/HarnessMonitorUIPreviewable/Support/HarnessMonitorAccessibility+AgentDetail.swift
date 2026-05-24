extension HarnessMonitorAccessibility {
  public static let decisionDeskRoot = "harness.decisions.desk"
  public static let agentDetailCard = "harness.agent.detail-card"
  public static let agentDetailAwaitingDecisionState =
    "harness.agent.detail.awaiting-decision.state"
  public static let agentDetailSignalCommand = "harness.agent.detail.signal-command"
  public static let agentDetailSignalMessage = "harness.agent.detail.signal-message"
  public static let agentDetailSignalAction = "harness.agent.detail.signal-action"
  public static let agentDetailSignalSend = "harness.agent.detail.signal-send"
  public static let agentDetailSignalDisclosure = "harness.agent.detail.signal-disclosure"
  public static let agentDetailSignalStatus = "harness.agent.detail.signal-status"
  public static let agentDetailPersona = "harness.agent.detail.persona"
  public static let agentDetailAssignedTasks = "harness.agent.detail.assigned-tasks"
  public static let agentDetailTimeline = "harness.agent.detail.timeline"
  public static let agentDetailRolePicker = "harness.agent.detail.role-picker"
  public static let agentDetailRoleChange = "harness.agent.detail.role-change"
  public static let agentDetailRoleRemove = "harness.agent.detail.role-remove"

  public static func agentTuiExternalTab(_ agentID: String) -> String {
    "harness.sheet.agent-tui.external-tab.\(slug(agentID))"
  }

  public static func agentPendingDecisionBadge(_ agentID: String) -> String {
    "harness.sheet.agent-tui.pending-decision-badge.\(slug(agentID))"
  }

  public static func agentDetailAwaitingDecisionStrip(_ agentID: String) -> String {
    "harness.agent.detail.awaiting-decision.\(slug(agentID))"
  }

  public static func agentDetailOpenDecisionsButton(_ agentID: String) -> String {
    "harness.agent.detail.awaiting-decision.open.\(slug(agentID))"
  }

  public static func agentDetailApproveDecisionButton(_ agentID: String) -> String {
    "harness.agent.detail.awaiting-decision.approve.\(slug(agentID))"
  }

  public static func agentDetailDenyDecisionButton(_ agentID: String) -> String {
    "harness.agent.detail.awaiting-decision.deny.\(slug(agentID))"
  }

  public static func agentRuntimeStrip(_ agentID: String) -> String {
    "harness.agent.detail.runtime.strip.\(slug(agentID))"
  }

  public static func agentRuntimeWatchdog(_ agentID: String) -> String {
    "harness.agent.detail.runtime.watchdog.\(slug(agentID))"
  }

  public static func agentRuntimePendingPermissions(_ agentID: String) -> String {
    "harness.agent.detail.runtime.pending-permissions.\(slug(agentID))"
  }

  public static func agentRuntimeDeadline(_ agentID: String) -> String {
    "harness.agent.detail.runtime.deadline.\(slug(agentID))"
  }

  public static func agentRuntimeDisclosure(_ agentID: String) -> String {
    "harness.agent.detail.runtime.disclosure.\(slug(agentID))"
  }

  public static func agentRuntimeDisclosureContent(_ agentID: String) -> String {
    "harness.agent.detail.runtime.disclosure-content.\(slug(agentID))"
  }

  public static func agentDetailReferenceDisclosure(_ agentID: String) -> String {
    "harness.agent.detail.reference.disclosure.\(slug(agentID))"
  }

  public static func agentDetailComposerInset(_ agentID: String) -> String {
    "harness.agent.detail.composer-inset.\(slug(agentID))"
  }

  public static func agentDetailRoleActionsDisclosure(_ agentID: String) -> String {
    "harness.agent.detail.role-actions.disclosure.\(slug(agentID))"
  }
}
