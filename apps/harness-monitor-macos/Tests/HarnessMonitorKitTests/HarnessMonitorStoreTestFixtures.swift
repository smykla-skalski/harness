@testable import HarnessMonitorKit

struct SessionFixture {
  var sessionId: String
  var title: String = ""
  var context: String
  var status: SessionStatus
  var projectName: String = "harness"
  var projectId: String = "project-a"
  var leaderId: String?
  var observeId: String?
  var openTaskCount: Int
  var inProgressTaskCount: Int
  var blockedTaskCount: Int
  var activeAgentCount: Int
  var lastActivityAt: String = "2026-03-28T14:18:00Z"
}

func makeProject(totalSessionCount: Int, activeSessionCount: Int) -> ProjectSummary {
  ProjectSummary(
    projectId: "project-a",
    name: "harness",
    projectDir: "/Users/example/Projects/harness",
    contextRoot: "/Users/example/Library/Application Support/harness/projects/project-a",
    activeSessionCount: activeSessionCount,
    totalSessionCount: totalSessionCount
  )
}

func makeSessionDetail(
  summary: SessionSummary,
  workerID: String,
  workerName: String
) -> SessionDetail {
  let leaderID = summary.leaderId ?? "leader-\(summary.sessionId)"
  let capabilities = PreviewFixtures.agents[0].runtimeCapabilities
  let leader = AgentRegistration(
    agentId: leaderID,
    name: "Leader \(summary.sessionId)",
    runtime: "claude",
    role: .leader,
    capabilities: ["general"],
    joinedAt: summary.createdAt,
    updatedAt: summary.updatedAt,
    status: .active,
    agentSessionId: "\(leaderID)-session",
    lastActivityAt: summary.lastActivityAt,
    currentTaskId: nil,
    runtimeCapabilities: capabilities,
    persona: nil
  )
  let worker = AgentRegistration(
    agentId: workerID,
    name: workerName,
    runtime: "codex",
    role: .worker,
    capabilities: ["general"],
    joinedAt: summary.createdAt,
    updatedAt: summary.updatedAt,
    status: .active,
    agentSessionId: "\(workerID)-session",
    lastActivityAt: summary.lastActivityAt,
    currentTaskId: nil,
    runtimeCapabilities: capabilities,
    persona: nil
  )

  return SessionDetail(
    session: summary,
    agents: [leader, worker],
    tasks: [],
    signals: [],
    observer: nil,
    agentActivity: []
  )
}

func makeTimelineEntries(
  sessionID: String,
  agentID: String,
  summary: String
) -> [TimelineEntry] {
  [
    TimelineEntry(
      entryId: "timeline-\(sessionID)",
      recordedAt: "2026-03-28T15:00:00Z",
      kind: "task_checkpoint",
      sessionId: sessionID,
      agentId: agentID,
      taskId: nil,
      summary: summary,
      payload: .object([:])
    )
  ]
}

func makeUpdatedSession(
  _ base: SessionSummary,
  context: String,
  updatedAt: String,
  agentCount: Int
) -> SessionSummary {
  SessionSummary(
    projectId: base.projectId,
    projectName: base.projectName,
    projectDir: base.projectDir,
    contextRoot: base.contextRoot,
    checkoutId: base.checkoutId,
    checkoutRoot: base.checkoutRoot,
    isWorktree: base.isWorktree,
    worktreeName: base.worktreeName,
    sessionId: base.sessionId,
    title: base.title,
    context: context,
    status: base.status,
    createdAt: base.createdAt,
    updatedAt: updatedAt,
    lastActivityAt: updatedAt,
    leaderId: base.leaderId,
    observeId: base.observeId,
    pendingLeaderTransfer: base.pendingLeaderTransfer,
    metrics: SessionMetrics(
      agentCount: agentCount,
      activeAgentCount: agentCount,
      openTaskCount: base.metrics.openTaskCount,
      inProgressTaskCount: base.metrics.inProgressTaskCount,
      blockedTaskCount: base.metrics.blockedTaskCount,
      completedTaskCount: base.metrics.completedTaskCount
    )
  )
}

func makeSession(_ fixture: SessionFixture) -> SessionSummary {
  SessionSummary(
    projectId: fixture.projectId,
    projectName: fixture.projectName,
    projectDir: "/Users/example/Projects/harness",
    contextRoot: "/Users/example/Library/Application Support/harness/projects/\(fixture.projectId)",
    sessionId: fixture.sessionId,
    title: fixture.title,
    context: fixture.context,
    status: fixture.status,
    createdAt: "2026-03-28T14:00:00Z",
    updatedAt: fixture.lastActivityAt,
    lastActivityAt: fixture.lastActivityAt,
    leaderId: fixture.leaderId,
    observeId: fixture.observeId,
    pendingLeaderTransfer: nil,
    metrics: SessionMetrics(
      agentCount: fixture.activeAgentCount,
      activeAgentCount: fixture.activeAgentCount,
      openTaskCount: fixture.openTaskCount,
      inProgressTaskCount: fixture.inProgressTaskCount,
      blockedTaskCount: fixture.blockedTaskCount,
      completedTaskCount: 0
    )
  )
}
