import Foundation

extension HarnessMonitorStore {
  /// Attributes every open Monitor decision to a Dashboard target — a managed agent, work item, or
  /// workspace — so the Agents destination groups and resolves them without Session terminology.
  ///
  /// Reads the already-materialized `supervisorOpenDecisions`, which the supervisor relay refreshes
  /// on every `DecisionEvent`, so callers observe updates by reading this through Observation.
  public func dashboardDecisionResolution(
    agents: [DashboardAgentSummary]
  ) -> DashboardDecisionResolution {
    let inputs = supervisorOpenDecisions.map(dashboardDecisionAttributionInput(for:))
    return DashboardDecisionAttributor.resolve(inputs: inputs, agents: agents)
  }

  /// Resolves a supervisor or manual decision through the shared action handler, which runs the
  /// chosen action against the daemon first and only marks the row resolved once the daemon
  /// accepts. A rejected or failed action leaves the decision open with surfaced feedback.
  public func resolveDashboardSupervisorDecision(
    decisionID: String,
    outcome: DecisionOutcome
  ) async {
    await supervisorDecisionActionHandler().resolve(decisionID: decisionID, outcome: outcome)
  }

  func dashboardDecisionAttributionInput(
    for decision: Decision
  ) -> DashboardDecisionAttributionInput {
    let workspace = decision.sessionID
      .flatMap { sessionIndex.sessionSummary(for: $0) }
      .map(Self.dashboardAgentWorkspace)
    return DashboardDecisionAttributionInput(
      id: decision.id,
      ruleID: decision.ruleID,
      severity: DecisionSeverity(rawValue: decision.severityRaw) ?? .info,
      summary: decision.summary,
      createdAt: decision.createdAt,
      sessionID: decision.sessionID,
      sessionAgentID: decision.agentID,
      taskID: decision.taskID,
      managedAgentID: dashboardDecisionManagedAgentID(for: decision),
      workspace: workspace,
      suggestedActions: Self.dashboardDecisionSuggestedActions(from: decision)
    )
  }

  private static func dashboardDecisionSuggestedActions(
    from decision: Decision
  ) -> [SuggestedAction] {
    guard let data = decision.suggestedActionsJSON.data(using: .utf8),
      let actions = try? JSONDecoder().decode([SuggestedAction].self, from: data)
    else {
      return []
    }
    return actions
  }

  /// The daemon-managed agent handle for an ACP permission decision. Prefers the live sync cache and
  /// falls back to decoding the persisted row, so a cold cache still attributes the decision.
  private func dashboardDecisionManagedAgentID(for decision: Decision) -> String? {
    guard decision.ruleID == AcpPermissionDecisionPayload.ruleID else { return nil }
    if let cached = acpPermissionDecisionPayload(for: decision.id)?.agent.managedAgentID,
      !cached.isEmpty
    {
      return cached
    }
    return AcpPermissionDecisionPayload.decode(from: decision)?.agent.managedAgentID
  }
}
