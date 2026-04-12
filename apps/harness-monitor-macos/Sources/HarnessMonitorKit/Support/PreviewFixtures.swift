import Foundation

public enum PreviewFixtures {
  public static let summary = SessionSummary(
    projectId: "project-6ccf8d0a",
    projectName: "harness",
    projectDir: "/Users/example/Projects/harness",
    contextRoot: "/Users/example/Library/Application Support/harness/projects/project-6ccf8d0a",
    sessionId: "sess-harness",
    title: "Harness Monitor Cockpit",
    context: "Track all live multi-agent harness sessions from a macOS cockpit",
    status: .active,
    createdAt: "2026-03-28T14:05:00Z",
    updatedAt: "2026-03-28T14:18:00Z",
    lastActivityAt: "2026-03-28T14:18:00Z",
    leaderId: "leader-claude",
    observeId: "observe-sess-harness",
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

  public static let taskDropTask = WorkItem(
    taskId: "task-drop-queue",
    title: "Queue the drag-and-drop smoke task",
    context: "Drag this open task onto the busy worker card.",
    severity: .medium,
    status: .open,
    assignedTo: nil,
    createdAt: "2026-03-28T14:10:00Z",
    updatedAt: "2026-03-28T14:10:00Z",
    createdBy: "leader-claude",
    notes: [],
    suggestedFix: "Drop it onto worker-codex and verify it becomes queued.",
    source: .manual,
    blockedReason: nil,
    completedAt: nil,
    checkpointSummary: nil
  )

  public static let taskDropTasks = [taskDropTask] + tasks

  public static let taskDropSummary = SessionSummary(
    projectId: summary.projectId,
    projectName: summary.projectName,
    projectDir: summary.projectDir,
    contextRoot: summary.contextRoot,
    checkoutId: summary.checkoutId,
    checkoutRoot: summary.checkoutRoot,
    isWorktree: summary.isWorktree,
    worktreeName: summary.worktreeName,
    sessionId: summary.sessionId,
    title: summary.title,
    context: summary.context,
    status: summary.status,
    createdAt: summary.createdAt,
    updatedAt: "2026-03-28T14:18:30Z",
    lastActivityAt: "2026-03-28T14:18:30Z",
    leaderId: summary.leaderId,
    observeId: summary.observeId,
    pendingLeaderTransfer: summary.pendingLeaderTransfer,
    metrics: SessionMetrics(
      agentCount: summary.metrics.agentCount,
      activeAgentCount: summary.metrics.activeAgentCount,
      openTaskCount: summary.metrics.openTaskCount + 1,
      inProgressTaskCount: summary.metrics.inProgressTaskCount,
      blockedTaskCount: summary.metrics.blockedTaskCount,
      completedTaskCount: summary.metrics.completedTaskCount
    )
  )

  public static let signals = [
    SessionSignalRecord(
      runtime: "codex",
      agentId: "worker-codex",
      sessionId: summary.sessionId,
      status: .delivered,
      signal: Signal(
        signalId: "sig-ui-1",
        version: 1,
        createdAt: "2026-03-28T14:12:00Z",
        expiresAt: "2026-03-28T14:20:00Z",
        sourceAgent: "leader-claude",
        command: "inject_context",
        priority: .high,
        payload: SignalPayload(
          message: """
            ## BackendRef recovery checklist

            Render the dangling backend reference request as Markdown:

            1. Apply a `MeshAccessLog` that references a missing MOTB.
            2. Verify the sidecar reports no rejected listener warnings.
            3. Confirm `UnresolvedBackendRefs` appears in policy status.
            4. Recover by creating the referenced MOTB and checking access logs again.

            ```bash
            harness run apply --manifest groups/g12
            ```
            """,
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

  public static let signalRegressionSecondarySummary = SessionSummary(
    projectId: summary.projectId,
    projectName: summary.projectName,
    projectDir: summary.projectDir,
    contextRoot: summary.contextRoot,
    sessionId: "sess-harness-secondary",
    title: "Signal retention verification",
    context: "Switch between sessions and make sure existing signal history survives each reload.",
    status: .active,
    createdAt: "2026-03-28T14:09:00Z",
    updatedAt: "2026-03-28T14:19:00Z",
    lastActivityAt: "2026-03-28T14:19:00Z",
    leaderId: summary.leaderId,
    observeId: "observe-sess-harness-secondary",
    pendingLeaderTransfer: nil,
    metrics: SessionMetrics(
      agentCount: 2,
      activeAgentCount: 2,
      openTaskCount: 1,
      inProgressTaskCount: 1,
      blockedTaskCount: 0,
      completedTaskCount: 2
    ),
  )

  public static let signalRegressionSessions = [
    summary,
    signalRegressionSecondarySummary,
  ]

  public static let signalRegressionProjects = [
    ProjectSummary(
      projectId: summary.projectId,
      name: summary.projectName,
      projectDir: summary.projectDir,
      contextRoot: summary.contextRoot,
      activeSessionCount: signalRegressionSessions.filter { $0.status == .active }.count,
      totalSessionCount: signalRegressionSessions.count
    )
  ]

  public static let overflowSessions: [SessionSummary] = {
    let titles = [
      "Sidebar live updates",
      "Timeline diff verification",
      "",
      "Observer text scaling",
      "Filter chip stress test",
      "Diagnostics reconnect",
      "",
      "Bookmark persistence",
      "Cockpit lazy sections",
      "Inspector card density",
      "",
      "Search grouping stability",
      "Sidebar scroll benchmark",
      "Filter reachability",
      "",
      "Idle vs active rendering",
      "Activity sort order",
      "Focus filter mixtures",
    ]

    let contexts = [
      "Track sidebar live updates without invalidating the whole window",
      "Verify task timeline diffs stay incremental under daemon push traffic",
      "Audit session selection redraw cost when recent searches change",
      "Confirm observer summaries remain readable at smaller text scales",
      "Stress test sidebar filter chips against a larger active session set",
      "Keep diagnostics cards responsive while the daemon reconnects",
      "Measure session board metric recomputation after narrow updates",
      "Review bookmark persistence when switching between many sessions",
      "Exercise cockpit lazy sections with a wider mix of session states",
      "Validate compact inspector cards when the agent roster grows",
      "Check pending leader transfer rendering under rapid timeline churn",
      "Confirm search result grouping stays stable with repeated refreshes",
      "Benchmark sidebar scrolling when open work and blocked counts spike",
      "Verify observed sessions remain reachable after repeated filter changes",
      "Inspect transport badge updates during session stream reconnects",
      "Compare idle and active session rendering in the grouped sidebar",
      "Confirm recent-activity sorting preserves the most active session first",
      "Review session focus filters with mixed observed and idle fixtures",
    ]

    return [summary]
      + zip(titles, contexts).enumerated().map { offset, pair in
        let (title, context) = pair
        let index = offset + 1
        let minute = 17 - min(offset, 15)
        let status: SessionStatus =
          switch index % 4 {
          case 0:
            .ended
          case 1:
            .active
          case 2:
            .paused
          default:
            .active
          }
        let activeAgentCount = status == .ended ? 0 : max(0, 3 - (index % 3))
        let openTaskCount = (index % 4) + (status == .ended ? 0 : 1)
        let inProgressTaskCount = status == .ended ? 0 : max(1, 3 - (index % 2))
        let blockedTaskCount = index.isMultiple(of: 3) ? 1 : 0

        return SessionSummary(
          projectId: summary.projectId,
          projectName: summary.projectName,
          projectDir: summary.projectDir,
          contextRoot: summary.contextRoot,
          sessionId: String(format: "sess-harness-%02d", index),
          title: title,
          context: context,
          status: status,
          createdAt: "2026-03-28T14:\(String(format: "%02d", max(minute - 1, 0))):00Z",
          updatedAt: "2026-03-28T14:\(String(format: "%02d", minute)):00Z",
          lastActivityAt: status == .ended
            ? nil : "2026-03-28T14:\(String(format: "%02d", minute)):30Z",
          leaderId: summary.leaderId,
          observeId: index.isMultiple(of: 2) ? "observe-sess-harness-\(index)" : nil,
          pendingLeaderTransfer: nil,
          metrics: SessionMetrics(
            agentCount: 4,
            activeAgentCount: activeAgentCount,
            openTaskCount: openTaskCount,
            inProgressTaskCount: inProgressTaskCount,
            blockedTaskCount: blockedTaskCount,
            completedTaskCount: 2 + index
          ),
        )
      }
  }()

  static func sessionDetail(
    session: SessionSummary,
    agents: [AgentRegistration] = agents,
    tasks: [WorkItem] = tasks,
    signals: [SessionSignalRecord] = [],
    observer: ObserverSummary? = nil,
    agentActivity: [AgentToolActivitySummary] = []
  ) -> SessionDetail {
    SessionDetail(
      session: session,
      agents: agents,
      tasks: tasks,
      signals: signals,
      observer: observer,
      agentActivity: agentActivity
    )
  }

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
