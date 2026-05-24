import Testing

@testable import HarnessMonitorKit

@MainActor
extension PersistenceSnapshotIntegrationTests {
  @Test("loadCachedSessionDetail restores canonical agent and task ordering")
  func loadCachedSessionDetailRestoresCanonicalOrdering() async throws {
    let store = harness.makeStore()
    let summary = makeSession(
      .init(
        sessionId: "sess-ordering",
        context: "Ordering",
        status: .active,
        leaderId: "leader-1",
        openTaskCount: 2,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 3
      ))

    let detail = SessionDetail(
      session: summary,
      agents: makeOrderingTestAgents(),
      tasks: makeOrderingTestTasks(),
      signals: [],
      observer: nil,
      agentActivity: []
    )

    await store.cacheSessionDetail(detail, timeline: [])
    let cached = try #require(await store.loadCachedSessionDetail(sessionID: "sess-ordering"))

    #expect(cached.detail.agents.map(\.agentId) == ["leader-1", "reviewer-1", "worker-1"])
    #expect(cached.detail.tasks.map(\.taskId) == ["task-b", "task-a", "task-c"])
  }

  private func makeOrderingTestAgents() -> [AgentRegistration] {
    let caps = PreviewFixtures.agents[0].runtimeCapabilities
    let stamp = "2026-04-12T10:05:00Z"
    return [
      AgentRegistration(
        agentId: "worker-1",
        name: "Worker",
        runtime: "codex",
        role: .worker,
        capabilities: [],
        joinedAt: "2026-04-12T10:01:00Z",
        updatedAt: stamp,
        status: .active,
        agentSessionId: "worker-1-session",
        lastActivityAt: stamp,
        currentTaskId: nil,
        runtimeCapabilities: caps,
        persona: nil
      ),
      AgentRegistration(
        agentId: "leader-1",
        name: "Leader",
        runtime: "claude",
        role: .leader,
        capabilities: [],
        joinedAt: "2026-04-12T10:00:00Z",
        updatedAt: stamp,
        status: .active,
        agentSessionId: "leader-1-session",
        lastActivityAt: stamp,
        currentTaskId: nil,
        runtimeCapabilities: caps,
        persona: nil
      ),
      AgentRegistration(
        agentId: "reviewer-1",
        name: "Reviewer",
        runtime: "codex",
        role: .reviewer,
        capabilities: [],
        joinedAt: "2026-04-12T10:02:00Z",
        updatedAt: stamp,
        status: .active,
        agentSessionId: "reviewer-1-session",
        lastActivityAt: stamp,
        currentTaskId: nil,
        runtimeCapabilities: caps,
        persona: nil
      ),
    ]
  }

  private func makeOrderingTestTasks() -> [WorkItem] {
    [
      WorkItem(
        taskId: "task-a",
        title: "A",
        context: nil,
        severity: .critical,
        status: .open,
        assignedTo: nil,
        createdAt: "2026-04-12T09:00:00Z",
        updatedAt: "2026-04-12T10:00:00Z",
        createdBy: nil,
        notes: [],
        suggestedFix: nil,
        source: .manual,
        blockedReason: nil,
        completedAt: nil,
        checkpointSummary: nil
      ),
      WorkItem(
        taskId: "task-b",
        title: "B",
        context: nil,
        severity: .critical,
        status: .open,
        assignedTo: nil,
        createdAt: "2026-04-12T09:05:00Z",
        updatedAt: "2026-04-12T10:00:00Z",
        createdBy: nil,
        notes: [],
        suggestedFix: nil,
        source: .manual,
        blockedReason: nil,
        completedAt: nil,
        checkpointSummary: nil
      ),
      WorkItem(
        taskId: "task-c",
        title: "C",
        context: nil,
        severity: .high,
        status: .open,
        assignedTo: nil,
        createdAt: "2026-04-12T09:10:00Z",
        updatedAt: "2026-04-12T10:01:00Z",
        createdBy: nil,
        notes: [],
        suggestedFix: nil,
        source: .manual,
        blockedReason: nil,
        completedAt: nil,
        checkpointSummary: nil
      ),
    ]
  }
}
