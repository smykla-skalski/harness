import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Cached model detail conversions")
struct CachedModelsDetailTests {
  let container: ModelContainer

  init() throws {
    container = try HarnessMonitorModelContainer.preview()
  }

  @Test("SessionSignalRecord round-trips through CachedSignalRecord")
  func signalRecordRoundTrip() throws {
    let signal = Signal(
      signalId: "sig-1",
      version: 1,
      createdAt: "2026-03-28T10:00:00Z",
      expiresAt: "2026-03-28T11:00:00Z",
      sourceAgent: "agent-1",
      command: "review",
      priority: .high,
      payload: SignalPayload(
        message: "Please review",
        actionHint: "code-review",
        relatedFiles: ["src/main.rs"],
        metadata: .object(["scope": .string("full")])
      ),
      delivery: DeliveryConfig(
        maxRetries: 3,
        retryCount: 0,
        idempotencyKey: "key-1"
      )
    )

    let ack = SignalAck(
      signalId: "sig-1",
      acknowledgedAt: "2026-03-28T10:05:00Z",
      result: .accepted,
      agent: "agent-2",
      sessionId: "sess-1",
      details: "On it"
    )

    let original = SessionSignalRecord(
      runtime: "claude",
      agentId: "agent-1",
      sessionId: "sess-1",
      status: .delivered,
      signal: signal,
      acknowledgment: ack
    )

    let cached = original.toCachedSignalRecord()
    container.mainContext.insert(cached)
    try container.mainContext.save()

    let descriptor = FetchDescriptor<CachedSignalRecord>()
    let fetched = try container.mainContext.fetch(descriptor)
    #expect(fetched.count == 1)

    let restored = fetched[0].toSessionSignalRecord()
    #expect(restored == original)
  }

  @Test("ObserverSummary round-trips through CachedObserver")
  func observerSummaryRoundTrip() throws {
    let original = ObserverSummary(
      observeId: "obs-1",
      lastScanTime: "2026-03-28T14:00:00Z",
      openIssueCount: 2,
      resolvedIssueCount: 5,
      mutedCodeCount: 1,
      activeWorkerCount: 1,
      openIssues: [
        ObserverIssueSummary(
          issueId: "iss-1",
          code: "E001",
          summary: "Missing error handling",
          severity: "high",
          category: "data_integrity",
          fingerprint: "abc123",
          firstSeenLine: 42,
          lastSeenLine: 42,
          occurrenceCount: 1,
          fixSafety: "safe",
          evidenceExcerpt: "unwrap without guard"
        )
      ],
      mutedCodes: ["W003"],
      activeWorkers: nil,
      cycleHistory: [
        ObserverCycleSummary(
          timestamp: "2026-03-28T13:00:00Z",
          fromLine: 1,
          toLine: 500,
          newIssues: 3,
          resolved: 1
        )
      ],
      agentSessions: nil
    )

    let cached = original.toCachedObserver()
    container.mainContext.insert(cached)
    try container.mainContext.save()

    let descriptor = FetchDescriptor<CachedObserver>()
    let fetched = try container.mainContext.fetch(descriptor)
    #expect(fetched.count == 1)

    let restored = fetched[0].toObserverSummary()
    #expect(restored == original)
  }

  @Test("AgentToolActivitySummary round-trips")
  func agentActivityRoundTrip() throws {
    let original = AgentToolActivitySummary(
      agentId: "agent-1",
      runtime: "claude",
      toolInvocationCount: 42,
      toolResultCount: 40,
      toolErrorCount: 2,
      latestToolName: "Read",
      latestEventAt: "2026-03-28T14:00:00Z",
      recentTools: ["Read", "Write", "Bash"]
    )

    let cached = original.toCachedAgentActivity()
    container.mainContext.insert(cached)
    try container.mainContext.save()

    let descriptor = FetchDescriptor<CachedAgentActivity>()
    let fetched = try container.mainContext.fetch(descriptor)
    #expect(fetched.count == 1)

    let restored = fetched[0].toAgentToolActivitySummary()
    #expect(restored == original)
  }

  @Test("CachedProject update-in-place preserves identity")
  func projectUpdateInPlace() throws {
    let summary = ProjectSummary(
      projectId: "proj-1",
      name: "harness",
      projectDir: "/tmp/harness",
      contextRoot: "/data/harness",
      activeSessionCount: 1,
      totalSessionCount: 2
    )

    let cached = summary.toCachedProject()
    container.mainContext.insert(cached)
    try container.mainContext.save()

    let updated = ProjectSummary(
      projectId: "proj-1",
      name: "harness-v2",
      projectDir: "/tmp/harness",
      contextRoot: "/data/harness",
      activeSessionCount: 5,
      totalSessionCount: 10
    )

    cached.update(from: updated)
    try container.mainContext.save()

    let descriptor = FetchDescriptor<CachedProject>()
    let fetched = try container.mainContext.fetch(descriptor)
    #expect(fetched.count == 1)
    #expect(fetched[0].toProjectSummary() == updated)
  }

  @Test("CachedSession update-in-place preserves relationships")
  func sessionUpdateInPlace() throws {
    let metrics = SessionMetrics(
      agentCount: 1,
      activeAgentCount: 1,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      completedTaskCount: 0
    )

    let original = SessionSummary(
      projectId: "proj-1",
      projectName: "harness",
      projectDir: nil,
      contextRoot: "/data",
      sessionId: "sess-1",
      title: "session alpha",
      context: "Original context",
      status: .active,
      createdAt: "2026-03-28T10:00:00Z",
      updatedAt: "2026-03-28T10:00:00Z",
      lastActivityAt: nil,
      leaderId: nil,
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: metrics
    )

    let cached = original.toCachedSession()
    container.mainContext.insert(cached)

    let agent = AgentRegistration(
      agentId: "agent-1",
      name: "Claude",
      runtime: "claude",
      role: .leader,
      capabilities: ["general"],
      joinedAt: "2026-03-28T10:00:00Z",
      updatedAt: "2026-03-28T10:00:00Z",
      status: .active,
      agentSessionId: nil,
      lastActivityAt: nil,
      currentTaskId: nil,
      runtimeCapabilities: RuntimeCapabilities(
        runtime: "claude",
        supportsNativeTranscript: false,
        supportsSignalDelivery: false,
        supportsContextInjection: false,
        typicalSignalLatencySeconds: 0,
        hookPoints: []
      ),
      persona: nil
    )

    let cachedAgent = agent.toCachedAgent()
    cached.agents.append(cachedAgent)
    try container.mainContext.save()

    let updatedMetrics = SessionMetrics(
      agentCount: 2,
      activeAgentCount: 2,
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      completedTaskCount: 0
    )

    let updatedSummary = SessionSummary(
      projectId: "proj-1",
      projectName: "harness",
      projectDir: nil,
      contextRoot: "/data",
      sessionId: "sess-1",
      title: "session alpha updated",
      context: "Updated context",
      status: .active,
      createdAt: "2026-03-28T10:00:00Z",
      updatedAt: "2026-03-28T15:00:00Z",
      lastActivityAt: "2026-03-28T15:00:00Z",
      leaderId: "agent-1",
      observeId: nil,
      pendingLeaderTransfer: nil,
      metrics: updatedMetrics
    )

    cached.update(from: updatedSummary)
    try container.mainContext.save()

    let descriptor = FetchDescriptor<CachedSession>()
    let fetched = try container.mainContext.fetch(descriptor)
    #expect(fetched.count == 1)
    #expect(fetched[0].toSessionSummary() == updatedSummary)
    #expect(fetched[0].agents.count == 1)
  }
}
