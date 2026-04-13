import Foundation

extension PreviewFixtures {
  public static let singleAgentSummary = SessionSummary(
    projectId: summary.projectId,
    projectName: summary.projectName,
    projectDir: summary.projectDir,
    contextRoot: summary.contextRoot,
    sessionId: "sess-harness-solo",
    title: "Solo agent session",
    context: "A session with only one agent to test single-agent UI states.",
    status: .active,
    createdAt: "2026-03-28T14:05:00Z",
    updatedAt: "2026-03-28T14:18:00Z",
    lastActivityAt: "2026-03-28T14:18:00Z",
    leaderId: "leader-claude",
    observeId: nil,
    pendingLeaderTransfer: nil,
    metrics: SessionMetrics(
      agentCount: 1,
      activeAgentCount: 1,
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      completedTaskCount: 0
    )
  )

  public static let singleAgentDetail = sessionDetail(
    session: singleAgentSummary,
    agents: [agents[0]],
    tasks: []
  )

  public static let singleAgentSessions = [singleAgentSummary]

  public static let singleAgentProjects = [
    ProjectSummary(
      projectId: summary.projectId,
      name: summary.projectName,
      projectDir: summary.projectDir,
      contextRoot: summary.contextRoot,
      activeSessionCount: 1,
      totalSessionCount: 1
    )
  ]

  public static let signalRegressionPrimaryCoreDetail = sessionDetail(
    session: summary,
    signals: [],
    observer: nil,
    agentActivity: []
  )

  public static let signalRegressionSecondaryDetail = sessionDetail(
    session: signalRegressionSecondarySummary
  )

  public static let signalRegressionSecondaryCoreDetail = sessionDetail(
    session: signalRegressionSecondarySummary
  )
}
