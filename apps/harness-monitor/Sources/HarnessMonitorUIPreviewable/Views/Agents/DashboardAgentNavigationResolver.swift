import HarnessMonitorKit

enum DashboardAgentNavigationResolver {
  static func selection(
    for target: DashboardAgentNavigationTarget,
    agents: [DashboardAgentSummary],
    decisions: DashboardDecisionResolution
  ) -> DashboardAgentsSelection? {
    switch target {
    case .identity(let identity):
      return agents.contains(where: { $0.identity == identity }) ? .agent(identity) : nil
    case .session(let sessionID):
      return agents.first(where: { $0.sessionID == sessionID }).map { .agent($0.identity) }
    case .sessionAgent(let sessionID, let agentID):
      return agents.first {
        $0.sessionID == sessionID
          && ($0.sessionAgentID == agentID || $0.managedAgentID == agentID)
      }.map { .agent($0.identity) }
    case .managedAgent(let sessionID, let runtimeKind, let managedAgentID):
      return agents.first {
        $0.sessionID == sessionID
          && $0.runtimeKind == runtimeKind
          && $0.managedAgentID == managedAgentID
      }.map { .agent($0.identity) }
    case .decision(let decisionID):
      guard let decision = decisions.allItems.first(where: { $0.id == decisionID }) else {
        return nil
      }
      return selection(for: decision.target)
    case .createTerminal:
      return nil
    }
  }

  private static func selection(
    for target: DashboardDecisionTarget
  ) -> DashboardAgentsSelection {
    switch target {
    case .agent(let identity):
      .agent(identity)
    case .workItem(let workspace, _), .workspace(let workspace):
      .workspaceDecisions(workspace)
    case .unattributed:
      .globalDecisions
    }
  }
}
