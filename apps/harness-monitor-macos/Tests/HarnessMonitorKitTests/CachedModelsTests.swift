import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Cached model conversions")
struct CachedModelsTests {
  let container: ModelContainer

  init() throws {
    container = try HarnessMonitorModelContainer.preview()
  }

  @Test("ProjectSummary round-trips through CachedProject")
  func projectSummaryRoundTrip() throws {
    let original = ProjectSummary(
      projectId: "proj-1",
      name: "harness",
      projectDir: "/tmp/harness",
      contextRoot: "/data/harness/projects/proj-1",
      activeSessionCount: 3,
      totalSessionCount: 5
    )
    try assertSwiftDataRoundTrip(
      original,
      cache: { $0.toCachedProject() },
      restore: { $0.toProjectSummary() },
      container: container
    )
  }

  @Test("SessionSummary round-trips through CachedSession")
  func sessionSummaryRoundTrip() throws {
    let original = SessionSummary(
      projectId: "proj-1",
      projectName: "harness",
      projectDir: "/tmp/harness",
      contextRoot: "/data/harness",
      sessionId: "sess-abc",
      title: "test session",
      context: "Test cockpit workflow",
      status: .active,
      createdAt: "2026-03-28T10:00:00Z",
      updatedAt: "2026-03-28T14:00:00Z",
      lastActivityAt: "2026-03-28T14:00:00Z",
      leaderId: "agent-leader",
      observeId: "observe-1",
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(
        agentCount: 2,
        activeAgentCount: 1,
        openTaskCount: 3,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        completedTaskCount: 5
      )
    )
    try assertSwiftDataRoundTrip(
      original,
      cache: { $0.toCachedSession() },
      restore: { $0.toSessionSummary() },
      container: container
    )
  }

  @Test("SessionSummary preserves leaderless degraded status through CachedSession")
  func sessionSummaryLeaderlessDegradedRoundTrip() throws {
    let original = SessionSummary(
      projectId: "proj-leaderless",
      projectName: "harness",
      projectDir: "/tmp/harness",
      contextRoot: "/data/harness",
      sessionId: "sess-leaderless",
      title: "leaderless session",
      context: "Persisted leaderless degraded session",
      status: .leaderlessDegraded,
      createdAt: "2026-04-17T09:33:46Z",
      updatedAt: "2026-04-17T10:14:49Z",
      lastActivityAt: "2026-04-17T10:14:49Z",
      leaderId: nil,
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: SessionMetrics(
        agentCount: 3,
        activeAgentCount: 0,
        openTaskCount: 2,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        completedTaskCount: 4
      )
    )
    try assertSwiftDataRoundTrip(
      original,
      cache: { $0.toCachedSession() },
      restore: { $0.toSessionSummary() },
      container: container
    )
  }

  @Test("SessionSummary preserves awaiting leader status through CachedSession")
  func sessionSummaryAwaitingLeaderRoundTrip() throws {
    let original = SessionSummary(
      projectId: "proj-awaiting",
      projectName: "harness",
      projectDir: "/tmp/harness",
      contextRoot: "/data/harness",
      sessionId: "sess-awaiting",
      title: "awaiting leader session",
      context: "Persisted pre-leader session",
      status: .awaitingLeader,
      createdAt: "2026-04-22T09:33:46Z",
      updatedAt: "2026-04-22T10:14:49Z",
      lastActivityAt: nil,
      leaderId: nil,
      observeId: nil,
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
    try assertSwiftDataRoundTrip(
      original,
      cache: { $0.toCachedSession() },
      restore: { $0.toSessionSummary() },
      container: container
    )
  }

  @Test("SessionSummary with pending transfer round-trips")
  func sessionSummaryWithTransferRoundTrip() throws {
    let transfer = PendingLeaderTransfer(
      requestedBy: "agent-a",
      currentLeaderId: "agent-leader",
      newLeaderId: "agent-b",
      requestedAt: "2026-03-28T15:00:00Z",
      reason: "leader unresponsive"
    )
    let original = SessionSummary(
      projectId: "proj-1",
      projectName: "harness",
      projectDir: nil,
      contextRoot: "/data/harness",
      sessionId: "sess-transfer",
      title: "transfer test",
      context: "Transfer test",
      status: .active,
      createdAt: "2026-03-28T10:00:00Z",
      updatedAt: "2026-03-28T15:00:00Z",
      lastActivityAt: nil,
      leaderId: "agent-leader",
      observeId: nil,
      pendingLeaderTransfer: transfer,
      metrics: SessionMetrics(
        agentCount: 2,
        activeAgentCount: 2,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        completedTaskCount: 0
      )
    )
    try assertSwiftDataRoundTrip(
      original,
      cache: { $0.toCachedSession() },
      restore: { $0.toSessionSummary() },
      container: container
    )
  }

  @Test("AgentRegistration round-trips through CachedAgent")
  func agentRegistrationRoundTrip() throws {
    let original = AgentRegistration(
      agentId: "agent-1",
      name: "Lead Claude",
      runtime: "claude",
      role: .leader,
      capabilities: ["general", "observe"],
      joinedAt: "2026-03-28T10:00:00Z",
      updatedAt: "2026-03-28T14:00:00Z",
      status: .active,
      agentSessionId: "asess-1",
      lastActivityAt: "2026-03-28T14:00:00Z",
      currentTaskId: "task-5",
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "claude",
        supportsNativeTranscript: true,
        supportsSignalDelivery: true,
        supportsContextInjection: false,
        typicalSignalLatencySeconds: 2,
        hookPoints: [
          HookIntegrationDescriptor(
            name: "pre-tool",
            typicalLatencySeconds: 1,
            supportsContextInjection: true
          )
        ]
      ),
      persona: nil
    )
    try assertSwiftDataRoundTrip(
      original,
      cache: { $0.toCachedAgent() },
      restore: { $0.toAgentRegistration() },
      container: container
    )
  }

  @Test("WorkItem round-trips through CachedWorkItem")
  func workItemRoundTrip() throws {
    let note = TaskNote(
      timestamp: "2026-03-28T11:00:00Z",
      agentId: "agent-1",
      text: "Started work"
    )
    let checkpointSummary = TaskCheckpointSummary(
      checkpointId: "cp-1",
      recordedAt: "2026-03-28T12:00:00Z",
      actorId: "agent-1",
      summary: "50% done",
      progress: 50
    )
    let original = WorkItem(
      taskId: "task-1",
      title: "Fix sidebar layout",
      context: "The sidebar overflows on narrow windows",
      severity: .high,
      status: .inProgress,
      assignedTo: "agent-1",
      queuePolicy: .reassignWhenFree,
      queuedAt: "2026-03-28T10:15:00Z",
      createdAt: "2026-03-28T10:00:00Z",
      updatedAt: "2026-03-28T14:00:00Z",
      createdBy: "agent-leader",
      notes: [note],
      suggestedFix: "Use GeometryReader",
      source: .observe,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: checkpointSummary
    )
    try assertSwiftDataRoundTrip(
      original,
      cache: { $0.toCachedWorkItem() },
      restore: { $0.toWorkItem() },
      container: container
    )
  }

  @Test("TimelineEntry round-trips through CachedTimelineEntry")
  func timelineEntryRoundTrip() throws {
    let original = TimelineEntry(
      entryId: "tl-1",
      recordedAt: "2026-03-28T10:00:00Z",
      kind: "task.created",
      sessionId: "sess-1",
      agentId: "agent-1",
      taskId: "task-1",
      summary: "Created task: Fix sidebar",
      payload: .object(["priority": .string("high")])
    )
    try assertSwiftDataRoundTrip(
      original,
      cache: { $0.toCachedTimelineEntry() },
      restore: { $0.toTimelineEntry() },
      container: container
    )
  }
}
