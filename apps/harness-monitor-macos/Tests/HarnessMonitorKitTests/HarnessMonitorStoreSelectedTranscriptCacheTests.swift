import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor selected transcript cache")
struct HarnessMonitorStoreSelectedTranscriptCacheTests {
  @Test("Selecting a session persists hydrated ACP transcript rows in the cache")
  func selectingSessionPersistsHydratedAcpTranscriptRows() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-selected-transcript-cache",
        context: "Selected transcript cache lane",
        status: .active,
        leaderId: "leader-selected-transcript-cache",
        observeId: "observe-selected-transcript-cache",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-selected-transcript-cache",
      workerName: "Worker Selected Transcript Cache"
    )
    let cockpitTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-selected-transcript-cache",
      summary: "Cockpit timeline row"
    )
    let transcriptEntry = TimelineEntry(
      entryId: "acp-selected-transcript-cache",
      recordedAt: "2026-04-28T00:00:20Z",
      kind: "assistant_message",
      sessionId: summary.sessionId,
      agentId: "worker-selected-transcript-cache",
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
    let container = try HarnessMonitorModelContainer.preview()
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(
      daemonController: daemon,
      modelContainer: container
    )
    await store.bootstrap()

    await store.selectSession(summary.sessionId)
    try await Task.sleep(for: .milliseconds(700))

    let cached = try #require(await store.loadCachedSessionDetail(sessionID: summary.sessionId))
    #expect(cached.transcript?.map(\.summary) == ["Dedicated ACP transcript row"])
    #expect(cached.transcriptSource == .direct)
  }

  @Test("Cached selected transcript restores back into the per-agent transcript view")
  func cachedSelectedTranscriptRestoresIntoAgentTranscriptView() async throws {
    let container = try HarnessMonitorModelContainer.preview()
    let summary = makeSession(
      .init(
        sessionId: "sess-selected-transcript-restore",
        context: "Selected transcript restore lane",
        status: .active,
        leaderId: "leader-selected-transcript-restore",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-selected-transcript-restore",
      workerName: "Worker Selected Transcript Restore"
    )
    let transcriptEntry = TimelineEntry(
      entryId: "acp-selected-transcript-restore",
      recordedAt: "2026-04-28T00:00:20Z",
      kind: "assistant_message",
      sessionId: summary.sessionId,
      agentId: "worker-selected-transcript-restore",
      taskId: nil,
      summary: "Restored transcript row",
      payload: .object(["runtime": .string("acp")])
    )
    let seedStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    await seedStore.cacheSessionDetail(
      detail,
      timeline: makeTimelineEntries(
        sessionID: summary.sessionId,
        agentID: "worker-selected-transcript-restore",
        summary: "Restore timeline row"
      ),
      transcript: [transcriptEntry]
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    store.selectedSessionID = summary.sessionId

    await store.restorePersistedSessionSelection(sessionID: summary.sessionId)

    #expect(
      store.acpTranscript(
        forAgent: "worker-selected-transcript-restore", sessionID: summary.sessionId
      )
      .map(\.summary) == ["Restored transcript row"]
    )
  }

  @Test(
    "Cached derived transcript keeps its provenance through a later selected-session cache write")
  func cachedDerivedTranscriptKeepsProvenanceThroughSelectedSessionRewrite() async throws {
    let container = try HarnessMonitorModelContainer.preview()
    let summary = makeSession(
      .init(
        sessionId: "sess-selected-transcript-derived",
        context: "Selected derived transcript lane",
        status: .active,
        leaderId: "leader-selected-transcript-derived",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-selected-transcript-derived",
      workerName: "Worker Selected Transcript Derived"
    )
    let cockpitRow = TimelineEntry(
      entryId: "selected-derived-cockpit",
      recordedAt: "2026-04-28T00:00:10Z",
      kind: "task_started",
      sessionId: summary.sessionId,
      agentId: "worker-selected-transcript-derived",
      taskId: nil,
      summary: "Selected derived cockpit row",
      payload: .object([:])
    )
    let derivedTranscriptRow = TimelineEntry(
      entryId: "selected-derived-transcript",
      recordedAt: "2026-04-28T00:00:20Z",
      kind: "assistant_text",
      sessionId: summary.sessionId,
      agentId: "worker-selected-transcript-derived",
      taskId: nil,
      summary: "Selected derived transcript row",
      payload: .object([
        "runtime": .string("gemini"),
        "event": .object([
          "type": .string("assistant_text"),
          "content": .string("Selected derived transcript row"),
        ]),
      ])
    )
    let seedStore = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    await seedStore.cacheSessionDetail(
      detail,
      timeline: [derivedTranscriptRow, cockpitRow],
      transcript: [derivedTranscriptRow],
      transcriptSource: .derived,
      timelineWindow: TimelineWindowResponse.fallbackMetadata(for: [
        derivedTranscriptRow, cockpitRow,
      ])
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(),
      modelContainer: container
    )
    store.selectedSessionID = summary.sessionId

    await store.restorePersistedSessionSelection(sessionID: summary.sessionId)
    #expect(store.selectedAcpTranscriptSource == .derived)

    let selectedSession = try #require(store.selectedSession)
    store.scheduleSelectedSessionCacheWrite(
      selectedSession,
      timeline: store.timeline,
      timelineWindow: store.timelineWindow
    )
    await store.flushPendingCacheWrite()

    let cached = try #require(await store.loadCachedSessionDetail(sessionID: summary.sessionId))
    #expect(cached.transcript?.map(\.summary) == ["Selected derived transcript row"])
    #expect(cached.transcriptSource == .derived)
  }

  // swiftlint:disable function_body_length
  @Test("Switching sessions before the transcript debounce flush keeps each cache row coherent")
  func switchingSessionsBeforeTranscriptFlushKeepsCacheRowsCoherent() async throws {
    let summaryA = makeSession(
      .init(
        sessionId: "sess-selected-transcript-a",
        context: "Selected transcript A",
        status: .active,
        leaderId: "leader-selected-transcript-a",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let summaryB = makeSession(
      .init(
        sessionId: "sess-selected-transcript-b",
        context: "Selected transcript B",
        status: .active,
        leaderId: "leader-selected-transcript-b",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detailA = makeSessionDetail(
      summary: summaryA,
      workerID: "worker-selected-transcript-a",
      workerName: "Worker Selected Transcript A"
    )
    let detailB = makeSessionDetail(
      summary: summaryB,
      workerID: "worker-selected-transcript-b",
      workerName: "Worker Selected Transcript B"
    )
    let timelineA = makeTimelineEntries(
      sessionID: summaryA.sessionId,
      agentID: "worker-selected-transcript-a",
      summary: "Timeline A"
    )
    let timelineB = makeTimelineEntries(
      sessionID: summaryB.sessionId,
      agentID: "worker-selected-transcript-b",
      summary: "Timeline B"
    )
    let transcriptA = TimelineEntry(
      entryId: "acp-selected-transcript-a",
      recordedAt: "2026-04-28T00:00:20Z",
      kind: "assistant_message",
      sessionId: summaryA.sessionId,
      agentId: "worker-selected-transcript-a",
      taskId: nil,
      summary: "Transcript A",
      payload: .object(["runtime": .string("acp")])
    )
    let transcriptB = TimelineEntry(
      entryId: "acp-selected-transcript-b",
      recordedAt: "2026-04-28T00:00:20Z",
      kind: "assistant_message",
      sessionId: summaryB.sessionId,
      agentId: "worker-selected-transcript-b",
      taskId: nil,
      summary: "Transcript B",
      payload: .object(["runtime": .string("acp")])
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summaryA, summaryB],
      detailsByID: [
        summaryA.sessionId: detailA,
        summaryB.sessionId: detailB,
      ],
      timelinesBySessionID: [
        summaryA.sessionId: timelineA,
        summaryB.sessionId: timelineB,
      ],
      detail: detailA
    )
    client.configureAcpTranscriptResponse(
      AcpTranscriptResponse(entries: [transcriptA]),
      for: summaryA.sessionId
    )
    client.configureAcpTranscriptResponse(
      AcpTranscriptResponse(entries: [transcriptB]),
      for: summaryB.sessionId
    )
    client.configureAcpTranscriptDelay(.milliseconds(25), for: summaryA.sessionId)
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: container
    )
    await store.bootstrap()

    await store.selectSession(summaryA.sessionId)
    for _ in 0..<20
    where store.acpTranscript(
      forAgent: "worker-selected-transcript-a",
      sessionID: summaryA.sessionId
    ).isEmpty {
      try await Task.sleep(for: .milliseconds(20))
    }
    await store.selectSession(summaryB.sessionId)
    try await Task.sleep(for: .milliseconds(500))
    await store.flushPendingCacheWrite()

    let cachedA = try #require(await store.loadCachedSessionDetail(sessionID: summaryA.sessionId))
    let cachedB = try #require(await store.loadCachedSessionDetail(sessionID: summaryB.sessionId))

    #expect(cachedA.timeline.map(\.summary) == ["Timeline A"])
    #expect(cachedA.transcript?.map(\.summary) == ["Transcript A"])
    #expect(cachedB.timeline.map(\.summary) == ["Timeline B"])
    #expect(cachedB.transcript?.map(\.summary) == ["Transcript B"])
  }
  // swiftlint:enable function_body_length
}
