import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreUpdateStreamTests {
  @Test("Push fallback timeline refresh is rate-limited for repeated selected-session updates")
  func pushFallbackTimelineRefreshIsRateLimitedForRepeatedSelectedSessionUpdates() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.activeTransport = .webSocket
    store.sessionPushFallbackDelay = .milliseconds(20)
    store.sessionPushFallbackMinimumInterval = .milliseconds(120)

    await store.selectSession(PreviewFixtures.summary.sessionId)
    let selectedWindow = try #require(store.timelineWindow)
    let baselineTimelineCalls = client.readCallCount(
      .timelineWindow(PreviewFixtures.summary.sessionId))

    store.scheduleSessionPushFallback(
      using: client,
      sessionID: PreviewFixtures.summary.sessionId
    )
    try? await Task.sleep(for: .milliseconds(50))

    let timelineKey = RecordingHarnessClient.ReadCall.timelineWindow(
      PreviewFixtures.summary.sessionId)
    #expect(client.readCallCount(timelineKey) == baselineTimelineCalls + 1)
    #expect(
      client.recordedTimelineWindowRequests(for: PreviewFixtures.summary.sessionId).last
        == .latest(
          limit: max(
            HarnessMonitorStore.initialSelectedTimelineWindowLimit, selectedWindow.pageSize
          ),
          knownRevision: selectedWindow.revision
        )
    )

    store.scheduleSessionPushFallback(
      using: client,
      sessionID: PreviewFixtures.summary.sessionId
    )
    try? await Task.sleep(for: .milliseconds(60))

    #expect(client.readCallCount(timelineKey) == baselineTimelineCalls + 1)

    try? await Task.sleep(for: .milliseconds(90))

    #expect(client.readCallCount(timelineKey) == baselineTimelineCalls + 2)

    store.stopAllStreams()
  }

  @Test("Push fallback timeline refresh prefers summary scope on HTTP transport")
  func pushFallbackTimelineRefreshPrefersSummaryScopeOnHTTPTransport() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.activeTransport = .httpSSE
    store.sessionPushFallbackDelay = .milliseconds(20)

    await store.selectSession(PreviewFixtures.summary.sessionId)
    let selectedWindow = try #require(store.timelineWindow)
    let baselineTimelineCalls = client.readCallCount(
      .timelineWindow(PreviewFixtures.summary.sessionId))

    store.scheduleSessionPushFallback(
      using: client,
      sessionID: PreviewFixtures.summary.sessionId
    )
    try? await Task.sleep(for: .milliseconds(50))

    let timelineKey = RecordingHarnessClient.ReadCall.timelineWindow(
      PreviewFixtures.summary.sessionId)
    #expect(client.readCallCount(timelineKey) == baselineTimelineCalls + 1)
    #expect(
      client.recordedTimelineWindowRequests(for: PreviewFixtures.summary.sessionId).last
        == .latest(
          limit: max(
            HarnessMonitorStore.initialSelectedTimelineWindowLimit, selectedWindow.pageSize
          ),
          knownRevision: selectedWindow.revision
        )
    )

    store.stopAllStreams()
  }

  @Test("Push fallback timeline refresh applies websocket summary batches progressively")
  func pushFallbackTimelineRefreshAppliesWebsocketSummaryBatchesProgressively() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.activeTransport = .webSocket
    store.sessionPushFallbackDelay = .milliseconds(20)

    let firstBatch = makeTimelineEntries(
      sessionID: PreviewFixtures.summary.sessionId,
      agentID: "worker-progressive-fallback",
      summary: "Fallback batch one"
    )
    let secondBatch = makeTimelineEntries(
      sessionID: PreviewFixtures.summary.sessionId,
      agentID: "worker-progressive-fallback",
      summary: "Fallback batch two"
    )

    await store.selectSession(PreviewFixtures.summary.sessionId)
    client.configureTimelineBatches(
      [firstBatch, secondBatch],
      batchDelay: .milliseconds(200),
      for: PreviewFixtures.summary.sessionId
    )

    store.scheduleSessionPushFallback(
      using: client,
      sessionID: PreviewFixtures.summary.sessionId
    )
    try? await Task.sleep(for: .milliseconds(60))

    #expect(store.timeline == firstBatch)

    try? await Task.sleep(for: .milliseconds(220))

    #expect(store.timeline == firstBatch + secondBatch)

    store.stopAllStreams()
  }

  @Test("Selected session update with deferred extensions preserves visible signals")
  func selectedSessionUpdateWithDeferredExtensionsPreservesVisibleSignals() async {
    let client = RecordingHarnessClient()
    let updatedSummary = SessionSummary(
      projectId: PreviewFixtures.summary.projectId,
      projectName: PreviewFixtures.summary.projectName,
      projectDir: PreviewFixtures.summary.projectDir,
      contextRoot: PreviewFixtures.summary.contextRoot,
      checkoutId: PreviewFixtures.summary.checkoutId,
      checkoutRoot: PreviewFixtures.summary.checkoutRoot,
      isWorktree: PreviewFixtures.summary.isWorktree,
      worktreeName: PreviewFixtures.summary.worktreeName,
      sessionId: PreviewFixtures.summary.sessionId,
      title: PreviewFixtures.summary.title,
      context: "Cockpit context updated",
      status: PreviewFixtures.summary.status,
      createdAt: PreviewFixtures.summary.createdAt,
      updatedAt: "2026-03-31T12:04:00Z",
      lastActivityAt: "2026-03-31T12:04:00Z",
      leaderId: PreviewFixtures.summary.leaderId,
      observeId: PreviewFixtures.summary.observeId,
      pendingLeaderTransfer: PreviewFixtures.summary.pendingLeaderTransfer,
      metrics: PreviewFixtures.summary.metrics
    )
    let coreOnlyDetail = SessionDetail(
      session: updatedSummary,
      agents: PreviewFixtures.detail.agents,
      tasks: PreviewFixtures.detail.tasks,
      signals: [],
      observer: nil,
      agentActivity: []
    )

    client.configureSessions(
      summaries: [PreviewFixtures.summary],
      detailsByID: [PreviewFixtures.summary.sessionId: PreviewFixtures.detail],
      timelinesBySessionID: [PreviewFixtures.summary.sessionId: PreviewFixtures.timeline]
    )
    client.configureSessionStream(
      events: [
        .sessionUpdated(
          recordedAt: "2026-03-31T12:04:00Z",
          sessionId: PreviewFixtures.summary.sessionId,
          detail: coreOnlyDetail,
          extensionsPending: true
        )
      ],
      for: PreviewFixtures.summary.sessionId
    )

    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client)
    )

    await store.bootstrap()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    try? await Task.sleep(for: .milliseconds(60))

    #expect(store.selectedSession?.session.context == "Cockpit context updated")
    #expect(store.selectedSession?.signals == PreviewFixtures.signals)
    #expect(store.timeline == PreviewFixtures.timeline)

    store.stopAllStreams()
  }
}
