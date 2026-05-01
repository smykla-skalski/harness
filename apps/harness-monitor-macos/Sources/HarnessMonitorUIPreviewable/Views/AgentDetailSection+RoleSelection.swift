import HarnessMonitorKit

extension AgentDetailSection {
  static func submittedRoleSelection(
    draftRole: SessionRole,
    agentRole: SessionRole
  ) -> SessionRole {
    normalizedRoleSelection(
      draftRole: draftRole,
      agentRole: agentRole
    )
  }

  static func normalizedRoleSelection(
    draftRole: SessionRole,
    agentRole: SessionRole
  ) -> SessionRole {
    let availableRoles = rolePickerOptions(for: agentRole)
    if availableRoles.contains(draftRole) {
      return draftRole
    }
    if availableRoles.contains(agentRole) {
      return agentRole
    }
    return availableRoles.first ?? agentRole
  }

  static func rolePickerOptions(for agentRole: SessionRole) -> [SessionRole] {
    if agentRole == .leader {
      return SessionRole.allCases
    }
    return SessionRole.allCases.filter { $0 != .leader }
  }
}
