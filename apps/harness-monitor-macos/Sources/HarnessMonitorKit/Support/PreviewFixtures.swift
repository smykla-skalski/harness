import Foundation

public enum PreviewFixtures {
  public static let summary = SessionSummary(
    projectId: "project-6ccf8d0a",
    projectName: "harness",
    projectDir: "/Users/example/Projects/harness",
    contextRoot: "/Users/example/Library/Application Support/harness/projects/project-6ccf8d0a",
    sessionId: "sess-monitor",
    context: "Monitor all live multi-agent harness sessions from a macOS cockpit",
    status: .active,
    createdAt: "2026-03-28T14:05:00Z",
    updatedAt: "2026-03-28T14:18:00Z",
    lastActivityAt: "2026-03-28T14:18:00Z",
    leaderId: "leader-claude",
    observeId: "observe-sess-monitor",
    pendingLeaderTransfer: nil,
    metrics: SessionMetrics(
      agentCount: 4,
      activeAgentCount: 3,
      openTaskCount: 2,
      inProgressTaskCount: 3,
      blockedTaskCount: 1,
      completedTaskCount: 5
    ),
  )

  public static let agents = [
    AgentRegistration(
      agentId: "leader-claude",
      name: "Claude Lead",
      runtime: "claude",
      role: .leader,
      capabilities: ["suite:create", "general"],
      joinedAt: "2026-03-28T14:05:00Z",
      updatedAt: "2026-03-28T14:18:00Z",
      status: .active,
      agentSessionId: "claude-session-1",
      lastActivityAt: "2026-03-28T14:18:00Z",
      currentTaskId: "task-routing",
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "claude",
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 5,
        hookPoints: [
          HookIntegrationDescriptor(
            name: "PreToolUse",
            typicalLatencySeconds: 5,
            supportsContextInjection: true
          )
        ]
      )
    ),
    AgentRegistration(
      agentId: "worker-codex",
      name: "Codex Worker",
      runtime: "codex",
      role: .worker,
      capabilities: ["general", "daemon"],
      joinedAt: "2026-03-28T14:06:00Z",
      updatedAt: "2026-03-28T14:17:00Z",
      status: .active,
      agentSessionId: "codex-session-2",
      lastActivityAt: "2026-03-28T14:17:00Z",
      currentTaskId: "task-ui",
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "codex",
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 5,
        hookPoints: [
          HookIntegrationDescriptor(
            name: "PreToolUse",
            typicalLatencySeconds: 5,
            supportsContextInjection: true
          )
        ]
      )
    ),
  ]

  public static let tasks = [
    WorkItem(
      taskId: "task-ui",
      title: "Finish the session cockpit timeline",
      context: "Need a merged timeline with tasks, agents, and signal acknowledgements.",
      severity: .high,
      status: .inProgress,
      assignedTo: "worker-codex",
      createdAt: "2026-03-28T14:07:00Z",
      updatedAt: "2026-03-28T14:17:30Z",
      createdBy: "leader-claude",
      notes: [
        TaskNote(
          timestamp: "2026-03-28T14:16:00Z",
          agentId: "worker-codex",
          text: "Merged daemon timeline entries with session checkpoints."
        )
      ],
      suggestedFix:
        "Use daemon timeline summaries directly instead of reconstructing them in SwiftUI.",
      source: .observe,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: TaskCheckpointSummary(
        checkpointId: "task-ui-cp-1",
        recordedAt: "2026-03-28T14:17:30Z",
        actorId: "worker-codex",
        summary: "Cockpit timeline rows and metric cards are now live-backed.",
        progress: 70
      )
    ),
    WorkItem(
      taskId: "task-routing",
      title: "Validate daemon bootstrap path resolution",
      context: "The app needs the exact XDG/App Support root used by harness on macOS.",
      severity: .medium,
      status: .blocked,
      assignedTo: "leader-claude",
      createdAt: "2026-03-28T14:08:00Z",
      updatedAt: "2026-03-28T14:14:00Z",
      createdBy: "leader-claude",
      notes: [],
      suggestedFix: "Mirror the Rust user_dirs behavior exactly.",
      source: .manual,
      blockedReason: "Waiting on local validation against the crate implementation.",
      completedAt: nil,
      checkpointSummary: nil
    ),
  ]

  public static let signals = [
    SessionSignalRecord(
      runtime: "codex",
      agentId: "worker-codex",
      sessionId: summary.sessionId,
      status: .acknowledged,
      signal: Signal(
        signalId: "sig-ui-1",
        version: 1,
        createdAt: "2026-03-28T14:12:00Z",
        expiresAt: "2026-03-28T14:20:00Z",
        sourceAgent: "leader-claude",
        command: "inject_context",
        priority: .high,
        payload: SignalPayload(
          message: "Focus on the session cockpit and preserve the daemon API contract.",
          actionHint: "Open the selected session timeline and refresh.",
          relatedFiles: ["src/daemon/protocol.rs"],
          metadata: .object(["source": .string("preview")])
        ),
        delivery: DeliveryConfig(maxRetries: 3, retryCount: 1, idempotencyKey: nil)
      ),
      acknowledgment: SignalAck(
        signalId: "sig-ui-1",
        acknowledgedAt: "2026-03-28T14:12:05Z",
        result: .accepted,
        agent: "worker-codex",
        sessionId: summary.sessionId,
        details: "Loaded and applied."
      )
    )
  ]
}
