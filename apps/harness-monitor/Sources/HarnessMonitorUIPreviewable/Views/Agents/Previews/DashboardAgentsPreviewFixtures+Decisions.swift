import Foundation
import HarnessMonitorKit

extension DashboardAgentsPreviewFixtures {
  /// A workspace with no loaded agents, registered so the work-item decision below resolves into a
  /// bucket-only section rather than colliding with an agent workspace.
  static let decisionBucketSession = SessionSummary(
    projectId: "platform-ops",
    projectName: "platform-ops",
    projectDir: "/Users/example/Projects/platform-ops",
    contextRoot: "/Users/example/Library/Application Support/harness/sessions/platform-ops",
    sessionId: "preview-bucket-session",
    worktreePath: "/Users/example/Projects/platform-ops/deploy",
    sharedPath: "/Users/example/Projects/platform-ops/memory",
    originPath: "/Users/example/Projects/platform-ops",
    branchRef: "deploy",
    title: "Platform ops deploy",
    context: "Deployment coordination worktree",
    status: .active,
    createdAt: "2026-08-02T10:00:00Z",
    updatedAt: "2026-08-02T11:30:00Z",
    lastActivityAt: "2026-08-02T11:30:00Z",
    leaderId: "platform-ops-leader",
    observeId: "observe-platform-ops",
    pendingLeaderTransfer: nil,
    metrics: SessionMetrics(
      agentCount: 0,
      activeAgentCount: 0,
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      completedTaskCount: 0
    )
  )

  /// Open decisions injected into a preview store to exercise Dashboard attribution: two supervisor
  /// rows and a manual row that attach to loaded agents, plus a work-item row with no agent that
  /// falls into a workspace bucket.
  static var previewDecisions: [Decision] {
    [
      decision(
        id: "stuck-agent:preview-acp",
        severity: .critical,
        ruleID: "stuck-agent",
        agentID: acpAgent.sessionAgentID,
        summary: "Copilot has not emitted output for 12 minutes",
        actions: [
          .init(id: "nudge", title: "Nudge agent", kind: .nudge, payloadJSON: "{}"),
          .init(id: "dismiss", title: "Dismiss", kind: .dismiss, payloadJSON: "{}"),
        ]
      ),
      decision(
        id: "failed-nudge-loop:preview-codex",
        severity: .needsUser,
        ruleID: "failed-nudge-loop",
        agentID: liveAgents[1].sessionAgentID,
        summary: "Three nudges in a row failed to land with the Codex run",
        actions: [
          .init(id: "nudge", title: "Nudge again", kind: .nudge, payloadJSON: "{}"),
          .init(id: "snooze", title: "Snooze", kind: .snooze, payloadJSON: "{}"),
          .init(id: "dismiss", title: "Dismiss", kind: .dismiss, payloadJSON: "{}"),
        ]
      ),
      decision(
        id: "manual-session-window:preview-terminal",
        severity: .warn,
        ruleID: "manual-session-window",
        agentID: liveAgents[0].sessionAgentID,
        summary: "Confirm the release checklist before merging the terminal agent's work",
        actions: [
          .init(id: "dismiss", title: "Acknowledge", kind: .dismiss, payloadJSON: "{}")
        ]
      ),
      decision(
        id: "unassigned-task:mesh-4821",
        severity: .needsUser,
        ruleID: "unassigned-task",
        sessionID: decisionBucketSession.sessionId,
        agentID: nil,
        taskID: "mesh-4821",
        summary: "Task mesh-4821 has waited 30 minutes with no assigned agent",
        actions: [
          .init(id: "assign", title: "Assign agent", kind: .assignTask, payloadJSON: "{}"),
          .init(id: "dismiss", title: "Dismiss", kind: .dismiss, payloadJSON: "{}"),
        ]
      ),
    ]
  }

  private static func decision(
    id: String,
    severity: DecisionSeverity,
    ruleID: String,
    sessionID: String? = "opaque-preview-correlation",
    agentID: String?,
    taskID: String? = nil,
    summary: String,
    actions: [SuggestedAction]
  ) -> Decision {
    Decision(
      id: id,
      severity: severity,
      ruleID: ruleID,
      sessionID: sessionID,
      agentID: agentID,
      taskID: taskID,
      summary: summary,
      contextJSON: "{}",
      suggestedActionsJSON: encodedActions(actions)
    )
  }

  private static func encodedActions(_ actions: [SuggestedAction]) -> String {
    guard let data = try? JSONEncoder().encode(actions),
      let json = String(data: data, encoding: .utf8)
    else {
      return "[]"
    }
    return json
  }
}
