import Testing

@testable import HarnessMonitorKit

extension HarnessMonitorStoreSessionWindowTranscriptTests {
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
