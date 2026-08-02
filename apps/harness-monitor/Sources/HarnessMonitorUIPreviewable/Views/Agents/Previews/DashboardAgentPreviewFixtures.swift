import HarnessMonitorKit

struct DashboardAgentPreviewSpec {
  let projectID: String
  let projectName: String
  let checkoutID: String
  let checkoutName: String
  let runtime: DashboardAgentRuntimeKind
  let managedID: String
  let name: String
  let lifecycle: DashboardAgentLifecycle
  let summary: String
}

extension DashboardAgentSummary {
  var cachedCopy: DashboardAgentSummary {
    DashboardAgentSummary(
      identity: identity,
      workspace: workspace,
      sessionID: sessionID,
      sessionAgentID: sessionAgentID,
      displayName: displayName,
      lifecycle: lifecycle,
      summary: summary,
      projectDirectory: projectDirectory,
      createdAt: createdAt,
      updatedAt: updatedAt,
      source: .cache
    )
  }
}
