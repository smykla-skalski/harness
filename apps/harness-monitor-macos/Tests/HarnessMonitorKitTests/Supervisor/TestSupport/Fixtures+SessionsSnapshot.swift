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
  /// Constructs a lightweight `HarnessMonitorStore` pre-populated with the seeds required by the
  /// supervisor snapshot tests. The controller is the real `PreviewDaemonController` in a
  /// non-running mode so no manifest watcher, daemon probe, or bootstrap kicks in.
  static func fixture(sessions scenario: SessionsFixture) -> HarnessMonitorStore {
    let store = HarnessMonitorStore(
      daemonController: PreviewDaemonController(
        fixtures: .empty,
        isDaemonRunning: false,
        isLaunchAgentInstalled: false
      ),
      voiceCapture: PreviewVoiceCaptureService(),
      daemonOwnership: .managed
    )
    switch scenario {
    case .twoActiveSessions:
      seedTwoActiveSessions(into: store)
    case .oneIdleAgent(let idleSeconds):
      seedOneIdleAgent(into: store, idleSeconds: idleSeconds)
    }
    return store
  }

  private static func seedTwoActiveSessions(into store: HarnessMonitorStore) {
    let summary1 = SessionsFixtureBuilder.activeSummary(
      sessionId: "sess-alpha",
      title: "Alpha session",
      updatedAt: SessionsFixtureBuilder.isoString(secondsBeforeFixed: 60)
    )
    let summary2 = SessionsFixtureBuilder.activeSummary(
      sessionId: "sess-beta",
      title: "Beta session",
      updatedAt: SessionsFixtureBuilder.isoString(secondsBeforeFixed: 45)
    )
    let agentsAlpha = SessionsFixtureBuilder.defaultAgents(
      lastActivityAt: SessionsFixtureBuilder.isoString(secondsBeforeFixed: 30)
    )
    let agentsBeta = SessionsFixtureBuilder.defaultAgents(
      lastActivityAt: SessionsFixtureBuilder.isoString(secondsBeforeFixed: 15)
    )
    let detailAlpha = SessionDetail(
      session: summary1,
      agents: agentsAlpha,
      tasks: SessionsFixtureBuilder.defaultTasks(assignedAgentID: agentsAlpha.first?.agentId),
      signals: [],
      observer: nil,
      agentActivity: []
    )
    let detailBeta = SessionDetail(
      session: summary2,
      agents: agentsBeta,
      tasks: SessionsFixtureBuilder.defaultTasks(assignedAgentID: agentsBeta.first?.agentId),
      signals: [],
      observer: nil,
      agentActivity: []
    )
    store.sessionIndex.replaceSnapshot(
      projects: [],
      sessions: [summary1, summary2]
    )
    store.selectedSessionID = summary1.sessionId
    store.selectedSession = detailAlpha
    store.connectionState = .online
    // Retain the second detail on the fixture so snapshot consumers that hydrate per-session
    // data can reach it. The supervisor snapshot itself reads only the selected detail today;
    // future rules that walk every session can extend this seed.
    _ = detailBeta
  }

  private static func seedOneIdleAgent(into store: HarnessMonitorStore, idleSeconds: Int) {
    let summary = SessionsFixtureBuilder.activeSummary(
      sessionId: "sess-idle",
      title: "Idle session",
      updatedAt: SessionsFixtureBuilder.isoString(secondsBeforeFixed: idleSeconds)
    )
    let idleAgent = SessionsFixtureBuilder.agent(
      agentId: "agent-idle",
      name: "Idle Worker",
      runtime: "claude",
      role: .worker,
      lastActivityAt: SessionsFixtureBuilder.isoString(secondsBeforeFixed: idleSeconds),
      currentTaskId: nil
    )
    let detail = SessionDetail(
      session: summary,
      agents: [idleAgent],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
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
        agentId: "leader-fixture",
        name: "Leader",
        runtime: "claude",
        role: .leader,
        lastActivityAt: lastActivityAt,
        currentTaskId: "task-fixture"
      ),
      agent(
        agentId: "worker-fixture",
        name: "Worker",
        runtime: "codex",
        role: .worker,
        lastActivityAt: lastActivityAt,
        currentTaskId: nil
      )
    ]
  }

  static func agent(
    agentId: String,
    name: String,
    runtime: String,
    role: SessionRole,
    lastActivityAt: String,
    currentTaskId: String?
  ) -> AgentRegistration {
    AgentRegistration(
      agentId: agentId,
      name: name,
      runtime: runtime,
      role: role,
      capabilities: [],
      joinedAt: isoString(secondsBeforeFixed: 3600),
      updatedAt: lastActivityAt,
      status: .active,
      agentSessionId: nil,
      lastActivityAt: lastActivityAt,
      currentTaskId: currentTaskId,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: runtime,
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
}
