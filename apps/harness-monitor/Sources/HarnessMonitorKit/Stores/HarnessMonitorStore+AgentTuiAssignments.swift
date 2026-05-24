import Foundation

extension HarnessMonitorStore {
  func upsertingAgentTui(
    _ tui: AgentTuiSnapshot,
    into tuis: [AgentTuiSnapshot]
  ) -> [AgentTuiSnapshot] {
    var updatedTuis = tuis.filter { $0.tuiId != tui.tuiId }
    updatedTuis.append(tui)
    return AgentTuiListResponse(tuis: updatedTuis)
      .canonicallySorted(roleByAgent: selectedSessionRoles()).tuis
  }

  func assignAgentTuis(_ tuis: [AgentTuiSnapshot], selected: AgentTuiSnapshot?) {
    if selectedAgentTuis != tuis {
      selectedAgentTuis = tuis
      scheduleUISync(.contentSessionDetail)
    }
    assignSelectedAgentTui(selected)
  }

  func assignSelectedAgentTui(_ tui: AgentTuiSnapshot?) {
    guard selectedAgentTui != tui else {
      return
    }
    selectedAgentTui = tui
  }

  func selectedSessionRoles() -> [String: SessionRole] {
    Dictionary(
      uniqueKeysWithValues: (selectedSession?.agents ?? []).map { ($0.agentId, $0.role) }
    )
  }
}
