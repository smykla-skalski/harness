import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor session window transcript")
struct HarnessMonitorStoreSessionWindowTranscriptTests {
  @Test("Session window snapshot uses dedicated ACP transcript without relying on selection")
  func sessionWindowSnapshotUsesDedicatedTranscriptWithoutSelection() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-acp-transcript",
        context: "Session window ACP transcript lane",
        status: .active,
        leaderId: "leader-window-acp",
        observeId: "observe-window-acp",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-acp",
      workerName: "Worker Window ACP"
    )
    let cockpitTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-window-acp",
      summary: "Cockpit timeline row"
    )
    let transcriptEntry = TimelineEntry(
      entryId: "acp-window-transcript",
      recordedAt: "2026-04-28T00:00:20Z",
      kind: "assistant_message",
      sessionId: summary.sessionId,
      agentId: "worker-window-acp",
      taskId: nil,
      summary: "Dedicated ACP transcript row",
      payload: .object(["runtime": .string("acp")])
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: cockpitTimeline],
      detail: detail
    )
    client.configureAcpTranscriptResponse(
      AcpTranscriptResponse(entries: [transcriptEntry]),
      for: summary.sessionId
    )
    let store = await makeBootstrappedStore(client: client)

    let snapshot = try #require(await store.sessionWindowSnapshot(sessionID: summary.sessionId))

    #expect(snapshot.source == .live)
    #expect(snapshot.transcriptSource == .direct)
    #expect(
      snapshot.timeline(forAgent: "worker-window-acp").map(\.summary) == ["Cockpit timeline row"])
    #expect(
      snapshot.transcript(forAgent: "worker-window-acp").map(\.summary)
        == ["Dedicated ACP transcript row"]
    )
    #expect(
      store.acpTranscript(forAgent: "worker-window-acp", sessionID: summary.sessionId).isEmpty)
  }

  @Test(
    "Session window snapshot derives transcript fallback from timeline when ACP transcript load fails"
  )
  func sessionWindowSnapshotDerivesTranscriptFallbackFromTimeline() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-acp-fallback",
        context: "Session window transcript fallback lane",
        status: .active,
        leaderId: "leader-window-fallback",
        observeId: "observe-window-fallback",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-fallback",
      workerName: "Worker Window Fallback"
    )
    let cockpitRow = TimelineEntry(
      entryId: "cockpit-row",
      recordedAt: "2026-04-28T00:00:10Z",
      kind: "task_started",
      sessionId: summary.sessionId,
      agentId: "worker-window-fallback",
      taskId: nil,
      summary: "Cockpit timeline row",
      payload: .object([:])
    )
    let transcriptRow = TimelineEntry(
      entryId: "gemini-worker-window-fallback-assistant_text-8",
      recordedAt: "2026-04-28T00:00:20Z",
      kind: "assistant_text",
      sessionId: summary.sessionId,
      agentId: "worker-window-fallback",
      taskId: nil,
      summary: "Managed native transcript row",
      payload: .object([
        "runtime": .string("gemini"),
        "event": .object([
          "type": .string("assistant_text"),
          "content": .string("Managed native transcript row"),
        ]),
      ])
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: [cockpitRow, transcriptRow]],
      detail: detail
    )
    client.configureAcpTranscriptError(
      HarnessMonitorAPIError.server(code: 500, message: "Transcript unavailable."),
      for: summary.sessionId
    )
    let store = await makeBootstrappedStore(client: client)

    let snapshot = try #require(await store.sessionWindowSnapshot(sessionID: summary.sessionId))

    #expect(snapshot.source == .live)
    #expect(snapshot.transcriptSource == .derived)
    #expect(
      snapshot.transcript(forAgent: "worker-window-fallback").map(\.summary)
        == ["Managed native transcript row"]
    )
    #expect(
      snapshot.timeline(forAgent: "worker-window-fallback").map(\.summary) == [
        "Cockpit timeline row",
        "Managed native transcript row",
      ])
  }

  @Test("Cached derived transcript re-derives after a later live timeline expansion")
  func cachedDerivedTranscriptRederivesAfterLiveTimelineExpansion() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-derived-cache",
        context: "Session window derived cache lane",
        status: .active,
        leaderId: "leader-window-derived-cache",
        observeId: "observe-window-derived-cache",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-derived-cache",
      workerName: "Worker Window Derived Cache"
    )
    let cockpitRow = TimelineEntry(
      entryId: "derived-cockpit-row",
      recordedAt: "2026-04-28T00:00:10Z",
      kind: "task_started",
      sessionId: summary.sessionId,
      agentId: "worker-window-derived-cache",
      taskId: nil,
      summary: "Derived cockpit row",
      payload: .object([:])
    )
    let transcriptRowA = TimelineEntry(
      entryId: "derived-transcript-a",
      recordedAt: "2026-04-28T00:00:20Z",
      kind: "assistant_text",
      sessionId: summary.sessionId,
      agentId: "worker-window-derived-cache",
      taskId: nil,
      summary: "Derived transcript row A",
      payload: .object([
        "runtime": .string("gemini"),
        "event": .object([
          "type": .string("assistant_text"),
          "content": .string("Derived transcript row A"),
        ]),
      ])
    )
    let transcriptRowB = TimelineEntry(
      entryId: "derived-transcript-b",
      recordedAt: "2026-04-28T00:00:30Z",
      kind: "assistant_text",
      sessionId: summary.sessionId,
      agentId: "worker-window-derived-cache",
      taskId: nil,
      summary: "Derived transcript row B",
      payload: .object([
        "runtime": .string("gemini"),
        "event": .object([
          "type": .string("assistant_text"),
          "content": .string("Derived transcript row B"),
        ]),
      ])
    )
    let container = try HarnessMonitorModelContainer.preview()
    let seedStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    await seedStore.cacheSessionDetail(
      detail,
      timeline: [transcriptRowA, cockpitRow],
      transcript: [transcriptRowA],
      transcriptSource: .derived,
      timelineWindow: TimelineWindowResponse.fallbackMetadata(for: [transcriptRowA, cockpitRow])
    )

    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: [transcriptRowB, transcriptRowA, cockpitRow]],
      detail: detail
    )
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: container
    )

    let cachedSnapshot = try #require(
      await store.sessionWindowSnapshot(sessionID: summary.sessionId))
    #expect(cachedSnapshot.source == .cache)
    #expect(cachedSnapshot.transcriptSource == .derived)
    #expect(
      cachedSnapshot.transcript(forAgent: "worker-window-derived-cache").map(\.summary)
        == ["Derived transcript row A"]
    )

    store.client = client
    store.connectionState = .online

    let refreshed = try #require(
      await store.loadSessionWindowTimeline(
        sessionID: summary.sessionId,
        snapshot: cachedSnapshot,
        request: .latest(limit: 10)
      )
    )

    #expect(refreshed.transcriptSource == .derived)
    #expect(
      refreshed.transcript(forAgent: "worker-window-derived-cache").map(\.summary)
        == ["Derived transcript row B", "Derived transcript row A"]
    )
  }
}
