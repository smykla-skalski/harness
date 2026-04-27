import Foundation

@testable import HarnessMonitorKit

/// Scenario catalog for `HarnessMonitorStore.fixture(sessions:)`. Phase 2 workers that need other
/// seeded snapshot shapes should grow this enum rather than hand-rolling stores per test file.
enum SessionsFixture: Sendable {
  /// Two active sessions that each carry a leader + worker. Used to assert the snapshot
  /// traversal visits every session the store knows about.
  case twoActiveSessions
  /// A single session with one agent whose last activity is `idleSeconds` before the fixed
  /// `Date.fixed` clock so the builder surfaces `idleSeconds` on the `AgentSnapshot`.
  case oneIdleAgent(idleSeconds: Int)
}

@MainActor
extension HarnessMonitorStore {
  /// Constructs a minimal `HarnessMonitorStore` with no seeded sessions. Used by tests that need
  /// a store object but don't care about snapshot content.
  static func fixture() -> HarnessMonitorStore {
    HarnessMonitorStore(
      daemonController: PreviewDaemonController(
        fixtures: .empty,
        isDaemonRunning: false,
        isLaunchAgentInstalled: false
      ),
      voiceCapture: PreviewVoiceCaptureService(),
      daemonOwnership: .managed
    )
  }

  /// Constructs a lightweight `HarnessMonitorStore` pre-populated with the seeds required by the
  /// supervisor snapshot tests. The controller is the real `PreviewDaemonController` in a
  /// non-running mode so no manifest watcher, daemon probe, or bootstrap kicks in.
  static func fixture(sessions scenario: SessionsFixture) async throws -> HarnessMonitorStore {
    let modelContainer = try HarnessMonitorModelContainer.preview()
    let cacheService = SessionCacheService(modelContainer: modelContainer)
    let store = HarnessMonitorStore(
      daemonController: PreviewDaemonController(
        fixtures: .empty,
        isDaemonRunning: false,
        isLaunchAgentInstalled: false
      ),
      voiceCapture: PreviewVoiceCaptureService(),
      daemonOwnership: .managed,
      modelContainer: modelContainer,
      cacheService: cacheService
    )
    switch scenario {
    case .twoActiveSessions:
      await seedTwoActiveSessions(into: store, cacheService: cacheService)
    case .oneIdleAgent(let idleSeconds):
      await seedOneIdleAgent(into: store, cacheService: cacheService, idleSeconds: idleSeconds)
    }
    return store
  }

  private static func seedTwoActiveSessions(
    into store: HarnessMonitorStore,
    cacheService: SessionCacheService
  ) async {
    let seed = SessionsFixtureBuilder.twoActiveSessionSeed()
    _ = await cacheService.cacheSessionList(seed.summaries, projects: [])
    _ = await cacheService.cacheSessionDetails(
      [
        .init(detail: seed.detailAlpha, timeline: seed.alphaTimeline, timelineWindow: nil),
        .init(detail: seed.detailBeta, timeline: seed.betaTimeline, timelineWindow: nil),
      ]
    )
    store.sessionIndex.replaceSnapshot(
      projects: [],
      sessions: seed.summaries
    )
    store.selectedSessionID = seed.summaryAlpha.sessionId
    store.selectedSession = seed.detailAlpha
    store.timeline = seed.alphaTimeline
    store.connectionState = .online
    store.activeTransport = .webSocket
    var metrics = ConnectionMetrics.initial
    metrics.transportKind = .webSocket
    metrics.lastMessageAt = Date.fixed.addingTimeInterval(-4)
    metrics.reconnectAttempt = 2
    store.connectionMetrics = metrics
    store.selectedCodexRuns = [seed.approvalRun]
    store.selectedCodexRun = seed.approvalRun
  }

  private static func seedOneIdleAgent(
    into store: HarnessMonitorStore,
    cacheService: SessionCacheService,
    idleSeconds: Int
  ) async {
    let summary = SessionsFixtureBuilder.activeSummary(
      sessionId: "sess-idle",
      title: "Idle session",
      updatedAt: SessionsFixtureBuilder.isoString(secondsBeforeFixed: idleSeconds)
    )
    let idleAgent = SessionsFixtureBuilder.agent(
      .init(
        id: "agent-idle",
        name: "Idle Worker",
        runtime: "claude",
        role: .worker,
        currentTaskId: nil
      ),
      lastActivityAt: SessionsFixtureBuilder.isoString(secondsBeforeFixed: idleSeconds)
    )
    let detail = SessionDetail(
      session: summary,
      agents: [idleAgent],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    _ = await cacheService.cacheSessionList([summary], projects: [])
    _ = await cacheService.cacheSessionDetails(
      [.init(detail: detail, timeline: [], timelineWindow: nil)]
    )
    store.sessionIndex.replaceSnapshot(projects: [], sessions: [summary])
    store.selectedSessionID = summary.sessionId
    store.selectedSession = detail
    store.connectionState = .online
  }
}

/// Helpers that assemble plain value types for the seeds above. Kept private to the TestSupport
/// module so production callers cannot accidentally depend on them.
private enum SessionsFixtureBuilder {
  struct TwoActiveSessionSeed {
    let summaryAlpha: SessionSummary
    let summaryBeta: SessionSummary
    let detailAlpha: SessionDetail
    let detailBeta: SessionDetail
    let alphaTimeline: [TimelineEntry]
    let betaTimeline: [TimelineEntry]
    let approvalRun: CodexRunSnapshot

    var summaries: [SessionSummary] { [summaryAlpha, summaryBeta] }
  }

  struct AgentSeed {
    let id: String
    let name: String
    let runtime: String
    let role: SessionRole
    let currentTaskId: String?
  }

  static func isoString(secondsBeforeFixed seconds: Int) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let date = Date.fixed.addingTimeInterval(-TimeInterval(seconds))
    return formatter.string(from: date)
  }

  static func activeSummary(
    sessionId: String,
    title: String,
    updatedAt: String
  ) -> SessionSummary {
    SessionSummary(
      projectId: "project-fixture",
      projectName: "fixture",
      projectDir: nil,
      contextRoot: "",
      sessionId: sessionId,
      worktreePath: "",
      sharedPath: "",
      originPath: "",
      branchRef: "",
      title: title,
      context: "fixture context for \(title)",
      status: .active,
      createdAt: isoString(secondsBeforeFixed: 3600),
      updatedAt: updatedAt,
      lastActivityAt: updatedAt,
      leaderId: "leader-fixture",
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

  static func defaultAgents(lastActivityAt: String) -> [AgentRegistration] {
    [
      agent(
        .init(
          id: "leader-fixture",
          name: "Leader",
          runtime: "claude",
          role: .leader,
          currentTaskId: "task-fixture"
        ),
        lastActivityAt: lastActivityAt
      ),
      agent(
        .init(
          id: "worker-fixture",
          name: "Worker",
          runtime: "codex",
          role: .worker,
          currentTaskId: nil
        ),
        lastActivityAt: lastActivityAt
      ),
    ]
  }

  static func agent(
    _ seed: AgentSeed,
    lastActivityAt: String
  ) -> AgentRegistration {
    AgentRegistration(
      agentId: seed.id,
      name: seed.name,
      runtime: seed.runtime,
      role: seed.role,
      capabilities: [],
      joinedAt: isoString(secondsBeforeFixed: 3600),
      updatedAt: lastActivityAt,
      status: .active,
      agentSessionId: nil,
      lastActivityAt: lastActivityAt,
      currentTaskId: seed.currentTaskId,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: seed.runtime,
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: true,
        typicalSignalLatencySeconds: 5,
        hookPoints: []
      ),
      persona: nil
    )
  }

  static func defaultTasks(assignedAgentID: String?) -> [WorkItem] {
    [
      WorkItem(
        taskId: "task-fixture",
        title: "Fixture task",
        context: nil,
        severity: .medium,
        status: .inProgress,
        assignedTo: assignedAgentID,
        createdAt: isoString(secondsBeforeFixed: 1800),
        updatedAt: isoString(secondsBeforeFixed: 120),
        createdBy: "leader-fixture",
        notes: [],
        suggestedFix: nil,
        source: .manual,
        blockedReason: nil,
        completedAt: nil,
        checkpointSummary: nil
      )
    ]
  }

  static func timelineEntry(
    id: String,
    sessionID: String,
    recordedAt: String
  ) -> TimelineEntry {
    TimelineEntry(
      entryId: id,
      recordedAt: recordedAt,
      kind: "task.updated",
      sessionId: sessionID,
      agentId: "leader-fixture",
      taskId: "task-fixture",
      summary: "Updated task",
      payload: .null
    )
  }

  static func twoActiveSessionSeed() -> TwoActiveSessionSeed {
    let summaryAlpha = activeSummary(
      sessionId: "sess-alpha",
      title: "Alpha session",
      updatedAt: isoString(secondsBeforeFixed: 60)
    )
    let summaryBeta = activeSummary(
      sessionId: "sess-beta",
      title: "Beta session",
      updatedAt: isoString(secondsBeforeFixed: 45)
    )
    let agentsAlpha = defaultAgents(lastActivityAt: isoString(secondsBeforeFixed: 30))
    let agentsBeta = defaultAgents(lastActivityAt: isoString(secondsBeforeFixed: 15))
    let detailAlpha = SessionDetail(
      session: summaryAlpha,
      agents: agentsAlpha,
      tasks: defaultTasks(assignedAgentID: agentsAlpha.first?.agentId),
      signals: [],
      observer: nil,
      agentActivity: []
    )
    let detailBeta = SessionDetail(
      session: summaryBeta,
      agents: agentsBeta,
      tasks: defaultTasks(assignedAgentID: agentsBeta.first?.agentId),
      signals: [],
      observer: betaObserverSummary(),
      agentActivity: []
    )
    let alphaTimeline = [
      timelineEntry(
        id: "timeline-alpha",
        sessionID: summaryAlpha.sessionId,
        recordedAt: isoString(secondsBeforeFixed: 20)
      )
    ]
    let betaTimeline = [
      timelineEntry(
        id: "timeline-beta",
        sessionID: summaryBeta.sessionId,
        recordedAt: isoString(secondsBeforeFixed: 10)
      )
    ]
    return TwoActiveSessionSeed(
      summaryAlpha: summaryAlpha,
      summaryBeta: summaryBeta,
      detailAlpha: detailAlpha,
      detailBeta: detailBeta,
      alphaTimeline: alphaTimeline,
      betaTimeline: betaTimeline,
      approvalRun: alphaApprovalRun(sessionID: summaryAlpha.sessionId)
    )
  }

  static func betaObserverSummary() -> ObserverSummary {
    let issue = ObserverIssueSummary(
      issueId: "issue-beta",
      code: "POL-001",
      summary: "Policy mismatch",
      severity: "warn",
      category: "policy",
      fingerprint: "fingerprint-beta",
      firstSeenLine: 12,
      lastSeenLine: 18,
      occurrenceCount: 3,
      fixSafety: "safe",
      evidenceExcerpt: "beta issue"
    )
    return ObserverSummary(
      observeId: "observe-beta",
      lastScanTime: isoString(secondsBeforeFixed: 5),
      openIssueCount: 1,
      resolvedIssueCount: 0,
      mutedCodeCount: 0,
      activeWorkerCount: 1,
      openIssues: [issue],
      mutedCodes: [],
      activeWorkers: [],
      agentSessions: []
    )
  }

  static func alphaApprovalRun(sessionID: String) -> CodexRunSnapshot {
    let approval = CodexApprovalRequest(
      approvalId: "approval-alpha",
      requestId: "request-alpha",
      kind: "command",
      title: "Approve command",
      detail: "run dangerous command",
      threadId: "thread-alpha",
      turnId: "turn-alpha",
      itemId: "item-alpha",
      cwd: "/tmp/alpha",
      command: "rm -rf /tmp/demo",
      filePath: nil
    )
    return CodexRunSnapshot(
      runId: "run-alpha",
      sessionId: sessionID,
      projectDir: "/tmp/alpha",
      threadId: "thread-alpha",
      turnId: "turn-alpha",
      mode: .approval,
      status: .waitingApproval,
      prompt: "review",
      latestSummary: nil,
      finalMessage: nil,
      error: nil,
      pendingApprovals: [approval],
      createdAt: isoString(secondsBeforeFixed: 40),
      updatedAt: isoString(secondsBeforeFixed: 4)
    )
  }
}
