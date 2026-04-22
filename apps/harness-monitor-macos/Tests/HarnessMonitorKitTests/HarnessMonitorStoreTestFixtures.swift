@testable import HarnessMonitorKit

struct SessionFixture {
  var sessionId: String
  var title: String = ""
  var context: String
  var status: SessionStatus
  var projectName: String = "harness"
  var projectId: String = "project-a"
  var projectDir: String = "/Users/example/Projects/harness"
  var originPath: String = ""
  var branchRef: String = ""
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
    sessionId: base.sessionId,
    worktreePath: base.worktreePath,
    sharedPath: base.sharedPath,
    originPath: base.originPath,
    branchRef: base.branchRef,
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
    projectDir: fixture.projectDir,
    contextRoot: "/Users/example/Library/Application Support/harness/projects/\(fixture.projectId)",
    sessionId: fixture.sessionId,
    originPath: fixture.originPath,
    branchRef: fixture.branchRef,
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

func makeSessionModelsSummary(
  projectDir: String = "/tmp/project",
  originPath: String = "/tmp/project"
) -> SessionSummary {
  SessionSummary(
    projectId: "project-b72ed763e074d381",
    projectName: "harness",
    projectDir: projectDir,
    contextRoot: "/tmp/harness/sessions/harness",
    sessionId: "sig12345",
    worktreePath: "/tmp/harness/sessions/harness/sig12345/workspace",
    sharedPath: "/tmp/harness/sessions/harness/sig12345/memory",
    originPath: originPath,
    branchRef: "harness/sig12345",
    title: "Signal decode proof",
    context: "Signal decode proof",
    status: .active,
    createdAt: "2026-04-03T17:23:26Z",
    updatedAt: "2026-04-03T17:23:32Z",
    lastActivityAt: "2026-04-03T17:23:32Z",
    leaderId: "claude-leader",
    observeId: nil,
    pendingLeaderTransfer: nil,
    metrics: SessionMetrics(
      agentCount: 2,
      activeAgentCount: 2,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      completedTaskCount: 0
    )
  )
}

let sessionSignalPayloadDefaultsFixture = """
  {
    "session": {
      "project_id": "project-b72ed763e074d381",
      "project_name": "harness",
      "project_dir": "/tmp/project",
      "context_root": "/tmp/harness/sessions/harness",
      "session_id": "sig12345",
      "worktree_path": "/tmp/harness/sessions/harness/sig12345/workspace",
      "shared_path": "/tmp/harness/sessions/harness/sig12345/memory",
      "origin_path": "/tmp/project",
      "branch_ref": "harness/sig12345",
      "context": "Signal decode proof",
      "status": "active",
      "created_at": "2026-04-03T17:23:26Z",
      "updated_at": "2026-04-03T17:23:32Z",
      "last_activity_at": "2026-04-03T17:23:32Z",
      "leader_id": "claude-leader",
      "observe_id": null,
      "pending_leader_transfer": null,
      "metrics": {
        "agent_count": 2,
        "active_agent_count": 2,
        "open_task_count": 0,
        "in_progress_task_count": 0,
        "blocked_task_count": 0,
        "completed_task_count": 0
      }
    },
    "agents": [
      {
        "agent_id": "claude-leader",
        "name": "claude leader",
        "runtime": "claude",
        "role": "leader",
        "capabilities": [],
        "joined_at": "2026-04-03T17:23:26Z",
        "updated_at": "2026-04-03T17:23:26Z",
        "status": "active",
        "last_activity_at": "2026-04-03T17:23:26Z",
        "runtime_capabilities": {
          "runtime": "claude",
          "supports_native_transcript": true,
          "supports_signal_delivery": true,
          "supports_context_injection": true,
          "typical_signal_latency_seconds": 5,
          "hook_points": []
        }
      }
    ],
    "tasks": [],
    "signals": [
      {
        "runtime": "codex",
        "agent_id": "codex-worker",
        "session_id": "sess-signal",
        "status": "acknowledged",
        "signal": {
          "signal_id": "sig-1",
          "version": 1,
          "created_at": "2026-04-03T17:24:00Z",
          "expires_at": "2026-04-03T17:39:00Z",
          "source_agent": "claude-leader",
          "command": "inject_context",
          "priority": "normal",
          "payload": {
            "message": "live payload without extra optional fields"
          },
          "delivery": {
            "max_retries": 3,
            "retry_count": 0,
            "idempotency_key": "sess-signal:codex-worker:inject_context"
          }
        },
        "acknowledgment": {
          "signal_id": "sig-1",
          "acknowledged_at": "2026-04-03T17:24:05Z",
          "result": "accepted",
          "agent": "worker-session",
          "session_id": "sess-signal"
        }
      }
    ],
    "observer": null,
    "agent_activity": []
  }
  """
