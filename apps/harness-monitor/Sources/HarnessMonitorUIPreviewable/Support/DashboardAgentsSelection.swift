import HarnessMonitorKit

/// Selection in the Dashboard Agents list: either a managed agent or a workspace's agent-less
/// decisions bucket.
///
/// Persisted as a string so `@AppStorage` and history restore keep working. The agent case reuses
/// the existing identity encoding verbatim, so selections stored before buckets existed still load;
/// the bucket case carries a distinct prefix that the agent decoder never matches.
enum DashboardAgentsSelection: Hashable {
  case agent(DashboardAgentIdentity)
  case workspaceDecisions(DashboardAgentWorkspaceIdentity)

  private static let workspacePrefix = "wsd:"

  var rawValue: String {
    switch self {
    case .agent(let identity):
      identity.selectionRawValue
    case .workspaceDecisions(let workspace):
      Self.workspacePrefix + workspace.selectionRawValue
    }
  }

  init?(rawValue: String) {
    guard !rawValue.isEmpty else { return nil }
    if rawValue.hasPrefix(Self.workspacePrefix) {
      let encoded = String(rawValue.dropFirst(Self.workspacePrefix.count))
      guard let workspace = DashboardAgentWorkspaceIdentity(selectionRawValue: encoded) else {
        return nil
      }
      self = .workspaceDecisions(workspace)
      return
    }
    guard let identity = DashboardAgentIdentity(selectionRawValue: rawValue) else { return nil }
    self = .agent(identity)
  }

  var agentIdentity: DashboardAgentIdentity? {
    if case .agent(let identity) = self { return identity }
    return nil
  }

  var workspaceIdentity: DashboardAgentWorkspaceIdentity? {
    if case .workspaceDecisions(let workspace) = self { return workspace }
    return nil
  }
}
