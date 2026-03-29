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
        targetFile: "Sources/Harness/Views/InspectorColumnView.swift",
        startedAt: "2026-03-28T14:16:55Z",
        agentId: "worker-gemini",
        runtime: "gemini"
      ),
    ],
    cycleHistory: [
      ObserverCycleSummary(
        timestamp: "2026-03-28T14:15:00Z",
        fromLine: 0,
        toLine: 72,
        newIssues: 2,
        resolved: 1
      ),
      ObserverCycleSummary(
        timestamp: "2026-03-28T14:17:45Z",
        fromLine: 72,
        toLine: 104,
        newIssues: 1,
        resolved: 0
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

  public static let detail = SessionDetail(
    session: summary,
    agents: agents,
    tasks: tasks,
    signals: signals,
    observer: observer,
    agentActivity: agentActivity
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
      summary: "sig-ui-1 acknowledged by worker-codex: accepted",
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
}
