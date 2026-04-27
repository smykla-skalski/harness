import Foundation

extension PreviewFixtures {
  public static let observer = ObserverSummary(
    observeId: "observe-sess-harness",
    lastScanTime: "2026-03-28T14:17:45Z",
    openIssueCount: 3,
    resolvedIssueCount: 4,
    mutedCodeCount: 1,
    activeWorkerCount: 2,
    openIssues: [
      ObserverIssueSummary(
        issueId: "issue-1",
        code: "agent_stalled_progress",
        summary: "worker-codex stalled while waiting on the signal ack",
        severity: "critical",
        category: "agent_coordination",
        fingerprint: "issue-1-fingerprint",
        firstSeenLine: 42,
        lastSeenLine: 48,
        occurrenceCount: 2,
        fixSafety: "triage_required",
        evidenceExcerpt: "No progress checkpoint after 12 minutes."
      ),
      ObserverIssueSummary(
        issueId: "issue-2",
        code: "tool_misuse",
        summary: "agent used shell tooling for a pure daemon read",
        severity: "medium",
        category: "tool_error",
        fingerprint: "issue-2-fingerprint",
        firstSeenLine: 76,
        lastSeenLine: 76,
        occurrenceCount: 1,
        fixSafety: "safe",
        evidenceExcerpt: "Prefer the Harness daemon API for session detail."
      ),
      ObserverIssueSummary(
        issueId: "issue-3",
        code: "repeated_error",
        summary: "observer keeps seeing the same 529 daemon failure",
        severity: "low",
        category: "workflow_error",
        fingerprint: "issue-3-fingerprint",
        firstSeenLine: 91,
        lastSeenLine: 94,
        occurrenceCount: 3,
        fixSafety: "safe",
        evidenceExcerpt: "Retry pattern needs a softer heuristic."
      ),
    ],
    mutedCodes: ["agent_repeated_error"],
    activeWorkers: [
      ObserverWorkerSummary(
        issueId: "issue-1",
        targetFile: "src/daemon/timeline.rs",
        startedAt: "2026-03-28T14:16:30Z",
        agentId: "worker-codex",
        runtime: "codex"
      ),
      ObserverWorkerSummary(
        issueId: "issue-2",
        targetFile: "Sources/HarnessMonitor/Views/InspectorColumnView.swift",
        startedAt: "2026-03-28T14:16:55Z",
        agentId: "worker-gemini",
        runtime: "gemini"
      ),
    ],
    agentSessions: [
      ObserverAgentSessionSummary(
        agentId: "leader-claude",
        runtime: "claude",
        logPath:
          "/Users/example/Library/Application Support/harness/projects/project-6ccf8d0a/"
          + "agents/sessions/claude/claude-session-1/raw.jsonl",
        cursor: 104,
        lastActivity: "2026-03-28T14:18:00Z"
      ),
      ObserverAgentSessionSummary(
        agentId: "worker-codex",
        runtime: "codex",
        logPath:
          "/Users/example/Library/Application Support/harness/projects/project-6ccf8d0a/"
          + "agents/sessions/codex/codex-session-2/raw.jsonl",
        cursor: 98,
        lastActivity: "2026-03-28T14:17:00Z"
      ),
    ]
  )

  public static let agentActivity = [
    AgentToolActivitySummary(
      agentId: "leader-claude",
      runtime: "claude",
      toolInvocationCount: 6,
      toolResultCount: 6,
      toolErrorCount: 0,
      latestToolName: "Read",
      latestEventAt: "2026-03-28T14:18:00Z",
      recentTools: ["Read", "Glob", "Grep"]
    ),
    AgentToolActivitySummary(
      agentId: "worker-codex",
      runtime: "codex",
      toolInvocationCount: 9,
      toolResultCount: 9,
      toolErrorCount: 1,
      latestToolName: "Edit",
      latestEventAt: "2026-03-28T14:17:30Z",
      recentTools: ["Edit", "Read", "Bash"]
    ),
  ]

  public static let detail = sessionDetail(
    session: summary,
    signals: signals,
    observer: observer,
    agentActivity: agentActivity
  )

  public static let taskDropDetail = sessionDetail(
    session: taskDropSummary,
    tasks: taskDropTasks,
    signals: signals,
    observer: observer,
    agentActivity: agentActivity
  )

  public static let emptyCockpitSummary = SessionSummary(
    projectId: summary.projectId,
    projectName: summary.projectName,
    projectDir: summary.projectDir,
    contextRoot: summary.contextRoot,
    sessionId: "sessempty",
    worktreePath: summary.worktreePath,
    sharedPath: summary.sharedPath,
    originPath: summary.originPath,
    branchRef: "harness/sessempty",
    title: "Harness Monitor Empty Cockpit",
    context:
      "Preview the compact cockpit placeholders without tasks, agents, signals, or timeline activity.",
    status: .awaitingLeader,
    createdAt: "2026-03-28T14:05:00Z",
    updatedAt: "2026-03-28T14:20:00Z",
    lastActivityAt: nil,
    leaderId: nil,
    observeId: nil,
    pendingLeaderTransfer: nil,
    metrics: SessionMetrics(
      agentCount: 0,
      activeAgentCount: 0,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      completedTaskCount: 0
    )
  )

  public static let emptyCockpitDetail = sessionDetail(
    session: emptyCockpitSummary,
    agents: [],
    tasks: [],
    signals: [],
    observer: nil,
    agentActivity: []
  )

  public static let timeline = [
    TimelineEntry(
      entryId: "codex-worker-codex-tool-result-4",
      recordedAt: "2026-03-28T14:17:35Z",
      kind: "tool_result",
      sessionId: summary.sessionId,
      agentId: "worker-codex",
      taskId: nil,
      summary: "worker-codex received a result from Edit",
      payload: .object([
        "runtime": .string("codex"),
        "event": .object([
          "type": .string("tool_result"),
          "tool_name": .string("Edit"),
        ]),
      ])
    ),
    TimelineEntry(
      entryId: "log-24",
      recordedAt: "2026-03-28T14:17:45Z",
      kind: "task_checkpoint",
      sessionId: summary.sessionId,
      agentId: "worker-codex",
      taskId: "task-ui",
      summary: "Checkpoint 70%: Cockpit timeline rows and metric cards are now live-backed.",
      payload: .object(["progress": .number(70)])
    ),
    TimelineEntry(
      entryId: "log-23",
      recordedAt: "2026-03-28T14:12:05Z",
      kind: "signal_acknowledged",
      sessionId: summary.sessionId,
      agentId: "worker-codex",
      taskId: nil,
      summary: "sig-ui-1 delivered to worker-codex: accepted",
      payload: .object(["result": .string("accepted")])
    ),
    TimelineEntry(
      entryId: "log-22",
      recordedAt: "2026-03-28T14:12:00Z",
      kind: "signal_sent",
      sessionId: summary.sessionId,
      agentId: "leader-claude",
      taskId: nil,
      summary: "sig-ui-1 sent to worker-codex: inject_context",
      payload: .object(["command": .string("inject_context")])
    ),
  ]

  public static let pagedTimeline: [TimelineEntry] = (0..<32).map { index in
    let eventNumber = 32 - index
    let minute = 18 - (index / 6)
    let second = 54 - (index * 3)
    let taskID = index.isMultiple(of: 3) ? "task-ui" : nil
    let kind = index.isMultiple(of: 2) ? "task_checkpoint" : "tool_result"

    return TimelineEntry(
      entryId: "paged-timeline-\(eventNumber)",
      recordedAt: String(
        format: "2026-03-28T14:%02d:%02dZ",
        minute,
        max(second, 0)
      ),
      kind: kind,
      sessionId: summary.sessionId,
      agentId: index.isMultiple(of: 2) ? "worker-codex" : "leader-claude",
      taskId: taskID,
      summary: "Paged timeline event \(String(format: "%02d", eventNumber))",
      payload: .object([
        "event_number": .number(Double(eventNumber)),
        "page_seed": .string("paged-timeline"),
      ])
    )
  }

  public static let projects = [
    ProjectSummary(
      projectId: summary.projectId,
      name: summary.projectName,
      projectDir: summary.projectDir,
      contextRoot: summary.contextRoot,
      activeSessionCount: 1,
      totalSessionCount: 1
    )
  ]

  public static func timelineBurst(batch: Int) -> [TimelineEntry] {
    let burstCount = max(batch, 1) * 12
    let burstEntries = (0..<burstCount).map { index in
      let totalSeconds = 30 * 60 + index
      let hour = 15 + totalSeconds / 3600
      let minute = (totalSeconds % 3600) / 60
      let second = totalSeconds % 60
      let recordedAt = String(
        format: "2026-03-28T%02d:%02d:%02dZ",
        hour % 24,
        minute,
        second
      )
      let taskID = index.isMultiple(of: 3) ? "task-ui" : nil
      let kind = index.isMultiple(of: 4) ? "task_checkpoint" : "tool_result"
      let entrySummary =
        index.isMultiple(of: 4)
        ? "Checkpoint \(min(99, 72 + batch + index % 6))%: timeline diff batch \(batch) committed."
        : "worker-codex processed preview burst event \(index + 1) in batch \(batch)."

      return TimelineEntry(
        entryId: "perf-timeline-\(batch)-\(index)",
        recordedAt: recordedAt,
        kind: kind,
        sessionId: summary.sessionId,
        agentId: index.isMultiple(of: 2) ? "worker-codex" : "leader-claude",
        taskId: taskID,
        summary: entrySummary,
        payload: .object([
          "batch": .number(Double(batch)),
          "index": .number(Double(index)),
        ])
      )
    }

    return burstEntries + timeline
  }
}
