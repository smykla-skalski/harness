import Foundation
import HarnessMonitorKit

extension DashboardAgentsPreviewFixtures {
  static let codexAgent = liveAgents[1]
  static let stoppedCodexAgent = codexAgent.with(
    lifecycle: .stopped,
    summary: "Stopped after the requested Dashboard review"
  )
  static let failedCodexAgent = codexAgent.with(
    lifecycle: .failed,
    summary: "The daemon persisted a transport failure"
  )

  static let stoppedCodexState = DashboardAgentBrowserViewState(
    agents: [stoppedCodexAgent],
    hasAttemptedLoad: true,
    source: .live,
    refreshedAt: Date(timeIntervalSince1970: 1_785_667_500)
  )

  static let failedCodexState = DashboardAgentBrowserViewState(
    agents: [failedCodexAgent],
    hasAttemptedLoad: true,
    source: .live,
    refreshedAt: Date(timeIntervalSince1970: 1_785_667_500)
  )

  static let managedCodexDetail = DashboardCodexAgentDetail(
    run: codexRun(
      status: .waitingApproval,
      pendingApprovals: [codexApproval],
      events: codexEvents
    ),
    inspect: codexInspect(status: .waitingApproval, attached: true),
    transcript: codexTranscript,
    issues: []
  )

  static let unavailableCodexDetail = DashboardCodexAgentDetail(
    run: nil,
    inspect: nil,
    transcript: [],
    issues: [
      "Managed agent unavailable: transport connection was lost",
      "Transcript unavailable: retry after the daemon reconnects",
    ]
  )

  static let stoppedCodexDetail = DashboardCodexAgentDetail(
    run: codexRun(status: .cancelled),
    inspect: codexInspect(status: .cancelled, attached: false),
    transcript: codexTranscript,
    issues: []
  )

  static let failedCodexDetail = DashboardCodexAgentDetail(
    run: codexRun(status: .failed, error: "Codex transport closed before completion"),
    inspect: codexInspect(status: .failed, attached: false),
    transcript: codexTranscript,
    issues: ["The daemon retained the terminal failure and transcript for retry"]
  )

  static let codexCatalog = RuntimeModelCatalog(
    runtime: AgentTuiRuntime.codex.rawValue,
    models: [
      RuntimeModel(
        id: "gpt-5.6-codex",
        displayName: "GPT-5.6 Codex",
        tier: .balanced,
        effortKind: .reasoningEffort,
        effortValues: ["low", "medium", "high"]
      ),
      RuntimeModel(
        id: "gpt-5.6-codex-mini",
        displayName: "GPT-5.6 Codex Mini",
        tier: .fast,
        effortKind: .reasoningEffort,
        effortValues: ["low", "medium"]
      ),
    ],
    default: "gpt-5.6-codex",
    cheapestFastest: "gpt-5.6-codex-mini"
  )

  private static let codexApproval = CodexApprovalRequest(
    approvalId: "preview-codex-approval",
    requestId: "preview-codex-request",
    kind: "command",
    title: "Approve preview snapshot generation",
    detail: "Allow Codex to generate the Dashboard preview snapshot in this worktree",
    threadId: "thread-codex-01",
    turnId: "turn-codex-01",
    itemId: "item-codex-01",
    cwd: codexAgent.projectDirectory,
    command: "mise run monitor:preview -- dashboard-agents tmp/preview-snapshots/issue-1338",
    filePath: nil
  )

  private static let codexEvents = [
    CodexRunEvent(
      eventId: "codex-event-1",
      sequence: 1,
      recordedAt: "2026-08-02T11:27:00Z",
      kind: "turn_started",
      summary: "Started the Dashboard Codex management turn",
      threadId: "thread-codex-01",
      turnId: "turn-codex-01",
      itemId: nil,
      payload: .null
    ),
    CodexRunEvent(
      eventId: "codex-event-2",
      sequence: 2,
      recordedAt: "2026-08-02T11:29:30Z",
      kind: "approval_requested",
      summary: "Requested approval to generate preview snapshots",
      threadId: "thread-codex-01",
      turnId: "turn-codex-01",
      itemId: "item-codex-01",
      payload: .null
    ),
  ]

  private static let codexTranscript = [
    TimelineEntry(
      entryId: "codex-transcript-1",
      recordedAt: "2026-08-02T11:27:00Z",
      kind: "user_message",
      sessionId: codexAgent.sessionID,
      agentId: codexAgent.sessionAgentID,
      taskId: nil,
      summary: "Implement durable Codex controls in Dashboard Agents",
      payload: codexIdentityPayload
    ),
    TimelineEntry(
      entryId: "codex-transcript-2",
      recordedAt: "2026-08-02T11:29:00Z",
      kind: "agent_message",
      sessionId: codexAgent.sessionID,
      agentId: codexAgent.sessionAgentID,
      taskId: nil,
      summary: "The managed run is waiting for snapshot approval",
      payload: codexIdentityPayload
    ),
  ]

  private static let codexIdentityPayload = JSONValue.object([
    "codex_timeline_identity": .object([
      "run_id": .string(codexAgent.managedAgentID),
      "agent_id": .string(codexAgent.sessionAgentID ?? "preview-codex-worker"),
      "thread_id": .string("thread-codex-01"),
      "turn_id": .string("turn-codex-01"),
    ])
  ])

  private static func codexRun(
    status: CodexRunStatus,
    pendingApprovals: [CodexApprovalRequest] = [],
    events: [CodexRunEvent] = [],
    error: String? = nil
  ) -> CodexRunSnapshot {
    CodexRunSnapshot(
      runId: codexAgent.managedAgentID,
      sessionId: codexAgent.sessionID,
      sessionAgentId: codexAgent.sessionAgentID,
      displayName: codexAgent.displayName,
      projectDir: codexAgent.projectDirectory,
      threadId: "thread-codex-01",
      turnId: "turn-codex-01",
      mode: .workspaceWrite,
      status: status,
      prompt: "Implement durable Codex controls in Dashboard Agents",
      latestSummary: codexAgent.summary,
      finalMessage: status == .completed ? "Dashboard Codex management is complete" : nil,
      error: error,
      pendingApprovals: pendingApprovals,
      events: events,
      createdAt: codexAgent.createdAt,
      updatedAt: codexAgent.updatedAt,
      model: "gpt-5.6-codex",
      effort: "high"
    )
  }

  private static func codexInspect(
    status: CodexRunStatus,
    attached: Bool
  ) -> CodexAgentInspectSnapshot {
    CodexAgentInspectSnapshot(
      runId: codexAgent.managedAgentID,
      sessionId: codexAgent.sessionID,
      agentId: codexAgent.sessionAgentID,
      displayName: codexAgent.displayName,
      status: status,
      projectDir: codexAgent.projectDirectory,
      threadId: "thread-codex-01",
      turnId: "turn-codex-01",
      active: status.isActive,
      attached: attached,
      pendingApprovals: status == .waitingApproval ? 1 : 0,
      resolvedApprovals: 0,
      eventCount: codexEvents.count,
      lastUpdateAt: codexAgent.updatedAt,
      model: "gpt-5.6-codex",
      effort: "high",
      latestSummary: codexAgent.summary,
      error: nil
    )
  }
}

extension DashboardAgentSummary {
  fileprivate func with(
    lifecycle: DashboardAgentLifecycle,
    summary: String
  ) -> DashboardAgentSummary {
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
      source: source
    )
  }
}
