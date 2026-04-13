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

    let cached = original.toCachedProject()
    container.mainContext.insert(cached)
    try container.mainContext.save()

    let descriptor = FetchDescriptor<CachedProject>()
    let fetched = try container.mainContext.fetch(descriptor)
    #expect(fetched.count == 1)

    let restored = fetched[0].toProjectSummary()
    #expect(restored == original)
  }

  @Test("SessionSummary round-trips through CachedSession")
  func sessionSummaryRoundTrip() throws {
    let metrics = SessionMetrics(
      agentCount: 2,
      activeAgentCount: 1,
      openTaskCount: 3,
      inProgressTaskCount: 1,
      blockedTaskCount: 0,
      completedTaskCount: 5
    )

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
      metrics: metrics
    )

    let cached = original.toCachedSession()
    container.mainContext.insert(cached)
    try container.mainContext.save()

    let descriptor = FetchDescriptor<CachedSession>()
    let fetched = try container.mainContext.fetch(descriptor)
    #expect(fetched.count == 1)

    let restored = fetched[0].toSessionSummary()
    #expect(restored == original)
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

    let metrics = SessionMetrics(
      agentCount: 2,
      activeAgentCount: 2,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      completedTaskCount: 0
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
      metrics: metrics
    )

    let cached = original.toCachedSession()
    container.mainContext.insert(cached)
    try container.mainContext.save()

    let descriptor = FetchDescriptor<CachedSession>()
    let fetched = try container.mainContext.fetch(descriptor)
    let restored = fetched[0].toSessionSummary()
    #expect(restored == original)
    #expect(restored.pendingLeaderTransfer == transfer)
  }

  @Test("AgentRegistration round-trips through CachedAgent")
  func agentRegistrationRoundTrip() throws {
    let capabilities = RuntimeCapabilities(
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
    )

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
      runtimeCapabilities: capabilities,
      persona: nil
    )

    let cached = original.toCachedAgent()
    container.mainContext.insert(cached)
    try container.mainContext.save()

    let descriptor = FetchDescriptor<CachedAgent>()
    let fetched = try container.mainContext.fetch(descriptor)
    #expect(fetched.count == 1)

    let restored = fetched[0].toAgentRegistration()
    #expect(restored == original)
  }

  @Test("WorkItem round-trips through CachedWorkItem")
  func workItemRoundTrip() throws {
    let checkpoint = TaskCheckpointSummary(
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
      notes: [
        TaskNote(timestamp: "2026-03-28T11:00:00Z", agentId: "agent-1", text: "Started work")
      ],
      suggestedFix: "Use GeometryReader",
      source: .observe,
      blockedReason: nil,
      completedAt: nil,
      checkpointSummary: checkpoint
    )

    let cached = original.toCachedWorkItem()
    container.mainContext.insert(cached)
    try container.mainContext.save()

    let descriptor = FetchDescriptor<CachedWorkItem>()
    let fetched = try container.mainContext.fetch(descriptor)
    #expect(fetched.count == 1)

    let restored = fetched[0].toWorkItem()
    #expect(restored == original)
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

    let cached = original.toCachedTimelineEntry()
    container.mainContext.insert(cached)
    try container.mainContext.save()

    let descriptor = FetchDescriptor<CachedTimelineEntry>()
    let fetched = try container.mainContext.fetch(descriptor)
    #expect(fetched.count == 1)

    let restored = fetched[0].toTimelineEntry()
    #expect(restored == original)
  }

}
