import Observation
import Testing
import SwiftData

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store selection flow")
struct HarnessMonitorStoreSelectionFlowTests {
  @Test("Refreshing diagnostics does not claim the global busy state")
  func refreshDiagnosticsDoesNotClaimGlobalBusyState() async {
    let client = RecordingHarnessClient()
    client.configureDiagnosticsDelay(.milliseconds(150))
    let store = await makeBootstrappedStore(client: client)

    let refreshTask = Task {
      await store.refreshDiagnostics()
    }
    await Task.yield()

    #expect(store.isDiagnosticsRefreshInFlight)
    #expect(store.isBusy == false)
    #expect(store.isDaemonActionInFlight == false)
    #expect(store.isSessionActionInFlight == false)

    await refreshTask.value

    #expect(store.isDiagnosticsRefreshInFlight == false)
  }

  @Test("Latest session selection wins when older load completes last")
  func latestSessionSelectionWinsWhenOlderLoadCompletesLast() async throws {
    let firstSummary = makeSession(
      .init(
        sessionId: "sess-a",
        context: "First cockpit lane",
        status: .active,
        leaderId: "leader-a",
        observeId: "observe-a",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let secondSummary = makeSession(
      .init(
        sessionId: "sess-b",
        context: "Second cockpit lane",
        status: .active,
        leaderId: "leader-b",
        observeId: "observe-b",
        openTaskCount: 0,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let firstDetail = makeSessionDetail(
      summary: firstSummary,
      workerID: "worker-a",
      workerName: "Worker A"
    )
    let secondDetail = makeSessionDetail(
      summary: secondSummary,
      workerID: "worker-b",
      workerName: "Worker B"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [firstSummary, secondSummary],
      detailsByID: [
        firstSummary.sessionId: firstDetail,
        secondSummary.sessionId: secondDetail,
      ],
      timelinesBySessionID: [
        firstSummary.sessionId: makeTimelineEntries(
          sessionID: firstSummary.sessionId,
          agentID: "worker-a",
          summary: "First timeline"
        ),
        secondSummary.sessionId: makeTimelineEntries(
          sessionID: secondSummary.sessionId,
          agentID: "worker-b",
          summary: "Second timeline"
        ),
      ],
      detail: firstDetail
    )
    client.configureDetailDelay(.milliseconds(250), for: firstSummary.sessionId)
    client.configureTimelineDelay(.milliseconds(250), for: firstSummary.sessionId)
    client.configureDetailDelay(.milliseconds(20), for: secondSummary.sessionId)
    client.configureTimelineDelay(.milliseconds(20), for: secondSummary.sessionId)
    let store = await makeBootstrappedStore(client: client)

    let firstSelection = Task {
      await store.selectSession(firstSummary.sessionId)
    }
    try await Task.sleep(for: .milliseconds(40))
    let secondSelection = Task {
      await store.selectSession(secondSummary.sessionId)
    }

    await secondSelection.value
    await firstSelection.value

    #expect(store.selectedSessionID == secondSummary.sessionId)
    #expect(store.selectedSession?.session.sessionId == secondSummary.sessionId)
    #expect(store.timeline.map(\.sessionId) == [secondSummary.sessionId])
    #expect(store.timeline.map(\.summary) == ["Second timeline"])
    #expect(store.actionActorID == secondSummary.leaderId)
    #expect(store.isSelectionLoading == false)
  }

  @Test("Selecting a session applies timeline batches before the full load completes")
  func selectingSessionAppliesTimelineBatchesProgressively() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-progressive",
        context: "Progressive timeline lane",
        status: .active,
        leaderId: "leader-progressive",
        observeId: "observe-progressive",
        openTaskCount: 1,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-progressive",
      workerName: "Worker Progressive"
    )
    let firstBatch = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-progressive",
      summary: "Timeline batch one"
    )
    let secondBatch = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-progressive",
      summary: "Timeline batch two"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      detail: detail
    )
    client.configureTimelineBatches(
      [firstBatch, secondBatch],
      batchDelay: .milliseconds(200),
      for: summary.sessionId
    )
    let store = await makeBootstrappedStore(client: client)

    let selectionTask = Task {
      await store.selectSession(summary.sessionId)
    }
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.selectedSession?.session.sessionId == summary.sessionId)
    #expect(store.timeline == firstBatch)
    #expect(store.isSelectionLoading)

    await selectionTask.value

    #expect(store.timeline == firstBatch + secondBatch)
    #expect(store.isSelectionLoading == false)
  }

  @Test("Selecting a cached session online keeps cached timeline visible during refresh")
  func selectingCachedSessionOnlineKeepsTimelineVisibleDuringRefresh() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-cached-visible",
        context: "Cached timeline lane",
        status: .active,
        leaderId: "leader-cached-visible",
        observeId: "observe-cached-visible",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-cached-visible",
      workerName: "Cached Worker"
    )
    let cachedTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: detail.agents[0].agentId,
      summary: "Cached timeline entry"
    )
    let liveTimeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: detail.agents[0].agentId,
      summary: "Live timeline entry"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: liveTimeline],
      detail: detail
    )
    client.configureDetailDelay(.milliseconds(20), for: summary.sessionId)
    client.configureTimelineDelay(.milliseconds(250), for: summary.sessionId)
    let container = try HarnessMonitorModelContainer.preview()
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(
      daemonController: daemon,
      modelContainer: container
    )
    await store.bootstrap()
    await store.cacheSessionDetail(detail, timeline: cachedTimeline, markViewed: false)

    let selectionTask = Task {
      await store.selectSession(summary.sessionId)
    }
    try await Task.sleep(for: .milliseconds(60))

    #expect(store.selectedSession?.session.sessionId == summary.sessionId)
    #expect(store.timeline == cachedTimeline)
    #expect(store.isShowingCachedData)

    await selectionTask.value

    #expect(store.timeline == liveTimeline)
    #expect(store.isShowingCachedData == false)
  }

  @Test("Selecting a cached session validates the latest window with the cached revision")
  func selectingCachedSessionValidatesLatestWindowWithCachedRevision() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-validate",
        context: "Window validation lane",
        status: .active,
        leaderId: "leader-window-validate",
        observeId: "observe-window-validate",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-validate",
      workerName: "Window Validate Worker"
    )
    let cachedTimeline = (0..<10).map { index in
      TimelineEntry(
        entryId: "cached-window-\(index)",
        recordedAt: String(format: "2026-04-14T10:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents.first?.agentId,
        taskId: nil,
        summary: "Cached window \(index)",
        payload: .object([:])
      )
    }
    let cachedWindow = TimelineWindowResponse(
      revision: 9,
      totalCount: 42,
      windowStart: 0,
      windowEnd: cachedTimeline.count,
      hasOlder: true,
      hasNewer: false,
      oldestCursor: cachedTimeline.last.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      newestCursor: cachedTimeline.first.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      entries: nil,
      unchanged: false
    )
    let unchangedWindow = TimelineWindowResponse(
      revision: cachedWindow.revision,
      totalCount: cachedWindow.totalCount,
      windowStart: cachedWindow.windowStart,
      windowEnd: cachedWindow.windowEnd,
      hasOlder: cachedWindow.hasOlder,
      hasNewer: cachedWindow.hasNewer,
      oldestCursor: cachedWindow.oldestCursor,
      newestCursor: cachedWindow.newestCursor,
      entries: nil,
      unchanged: true
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: cachedTimeline],
      detail: detail
    )
    client.configureTimelineWindowResponse(unchangedWindow, for: summary.sessionId)
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: container
    )
    await store.bootstrap()
    await store.cacheSessionDetail(
      detail,
      timeline: cachedTimeline,
      timelineWindow: cachedWindow,
      markViewed: false
    )
    let cachedSnapshot = try #require(
      await store.loadCachedSessionDetail(sessionID: summary.sessionId)
    )
    #expect(cachedSnapshot.timelineWindow?.revision == cachedWindow.revision)

    await store.selectSession(summary.sessionId)

    #expect(client.recordedTimelineWindowRequests(for: summary.sessionId) == [
      .latest(limit: cachedTimeline.count, knownRevision: cachedWindow.revision)
    ])
    #expect(store.timeline == cachedTimeline)
    #expect(store.timelineWindow?.totalCount == 42)
    #expect(store.timelineWindow?.windowEnd == cachedTimeline.count)
  }

  @Test("Selecting an uncached session requests only the latest timeline window")
  func selectingUncachedSessionRequestsOnlyLatestWindow() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-latest",
        context: "Windowed timeline lane",
        status: .active,
        leaderId: "leader-window-latest",
        observeId: "observe-window-latest",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-latest",
      workerName: "Window Worker"
    )
    let fullTimeline = (0..<25).map { index in
      TimelineEntry(
        entryId: "timeline-window-\(index)",
        recordedAt: String(
          format: "2026-03-29T12:%02d:00Z",
          59 - index
        ),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Window event \(index)",
        payload: .object([:])
      )
    }
    let pageSize = 10
    let latestWindowEntries = Array(fullTimeline.prefix(pageSize))
    let latestWindowResponse = TimelineWindowResponse(
      revision: 7,
      totalCount: fullTimeline.count,
      windowStart: 0,
      windowEnd: latestWindowEntries.count,
      hasOlder: true,
      hasNewer: false,
      oldestCursor: latestWindowEntries.last.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      newestCursor: latestWindowEntries.first.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      entries: latestWindowEntries,
      unchanged: false
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: fullTimeline],
      detail: detail
    )
    client.configureTimelineWindowResponse(latestWindowResponse, for: summary.sessionId)
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(summary.sessionId)

    #expect(client.recordedTimelineWindowRequests(for: summary.sessionId) == [
      .latest(limit: pageSize)
    ])
    #expect(client.readCallCount(.timeline(summary.sessionId)) == 0)
    #expect(store.timeline == latestWindowEntries)
  }

  @Test("Loading the next timeline page appends only the missing older prefix")
  func loadingNextTimelinePageAppendsOnlyMissingOlderPrefix() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-page-next",
        context: "Window prefix lane",
        status: .active,
        leaderId: "leader-window-page-next",
        observeId: "observe-window-page-next",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-page-next",
      workerName: "Window Prefix Worker"
    )
    let fullTimeline = (0..<25).map { index in
      TimelineEntry(
        entryId: "timeline-page-next-\(index)",
        recordedAt: String(format: "2026-04-14T10:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Window page next \(index)",
        payload: .object([:])
      )
    }
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: fullTimeline],
      detail: detail
    )
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(summary.sessionId)
    await store.loadSelectedTimelinePage(page: 1, pageSize: 10)

    #expect(client.recordedTimelineWindowRequests(for: summary.sessionId) == [
      .latest(limit: 10),
      TimelineWindowRequest(
        scope: .summary,
        limit: 10,
        before: TimelineCursor(
          recordedAt: fullTimeline[9].recordedAt,
          entryId: fullTimeline[9].entryId
        )
      ),
    ])
    #expect(store.timeline == Array(fullTimeline.prefix(20)))
    #expect(store.timelineWindow?.totalCount == fullTimeline.count)
    #expect(store.timelineWindow?.windowStart == 0)
    #expect(store.timelineWindow?.windowEnd == 20)
  }

  @Test("Loading a farther timeline page requests only the missing prefix")
  func loadingFartherTimelinePageRequestsOnlyMissingPrefix() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-page-far",
        context: "Window farther prefix lane",
        status: .active,
        leaderId: "leader-window-page-far",
        observeId: "observe-window-page-far",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-page-far",
      workerName: "Window Far Worker"
    )
    let fullTimeline = (0..<42).map { index in
      TimelineEntry(
        entryId: "timeline-page-far-\(index)",
        recordedAt: String(format: "2026-04-14T09:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Window page far \(index)",
        payload: .object([:])
      )
    }
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: fullTimeline],
      detail: detail
    )
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(summary.sessionId)
    await store.loadSelectedTimelinePage(page: 2, pageSize: 10)

    #expect(client.recordedTimelineWindowRequests(for: summary.sessionId) == [
      .latest(limit: 10),
      TimelineWindowRequest(
        scope: .summary,
        limit: 20,
        before: TimelineCursor(
          recordedAt: fullTimeline[9].recordedAt,
          entryId: fullTimeline[9].entryId
        )
      ),
    ])
    #expect(store.timeline == Array(fullTimeline.prefix(30)))
    #expect(store.timelineWindow?.totalCount == fullTimeline.count)
    #expect(store.timelineWindow?.windowEnd == 30)
  }

  @Test("Loading a timeline page falls back to a bounded latest refresh after revision drift")
  func loadingTimelinePageFallsBackToBoundedLatestRefreshAfterRevisionDrift() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-page-refresh",
        context: "Window refresh lane",
        status: .active,
        leaderId: "leader-window-page-refresh",
        observeId: "observe-window-page-refresh",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-page-refresh",
      workerName: "Window Refresh Worker"
    )
    let fullTimeline = (0..<25).map { index in
      TimelineEntry(
        entryId: "timeline-page-refresh-\(index)",
        recordedAt: String(format: "2026-04-14T08:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Window refresh \(index)",
        payload: .object([:])
      )
    }
    let refreshedPrefix = Array(fullTimeline.prefix(20))
    let driftedResponse = TimelineWindowResponse(
      revision: 99,
      totalCount: fullTimeline.count,
      windowStart: 0,
      windowEnd: refreshedPrefix.count,
      hasOlder: true,
      hasNewer: false,
      oldestCursor: refreshedPrefix.last.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      newestCursor: refreshedPrefix.first.map {
        TimelineCursor(recordedAt: $0.recordedAt, entryId: $0.entryId)
      },
      entries: refreshedPrefix,
      unchanged: false
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: fullTimeline],
      detail: detail
    )
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(summary.sessionId)
    client.configureTimelineWindowResponse(driftedResponse, for: summary.sessionId)

    await store.loadSelectedTimelinePage(page: 1, pageSize: 10)

    #expect(client.recordedTimelineWindowRequests(for: summary.sessionId) == [
      .latest(limit: 10),
      TimelineWindowRequest(
        scope: .summary,
        limit: 10,
        before: TimelineCursor(
          recordedAt: fullTimeline[9].recordedAt,
          entryId: fullTimeline[9].entryId
        )
      ),
      .latest(limit: 20),
    ])
    #expect(store.timeline == refreshedPrefix)
    #expect(store.timelineWindow?.revision == driftedResponse.revision)
    #expect(store.timelineWindow?.windowEnd == refreshedPrefix.count)
  }

  @Test("Selecting a session finishes before slow secondary panes hydrate")
  func selectingSessionFinishesBeforeSlowSecondaryPanesHydrate() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-secondary-hydration",
        context: "Secondary hydration lane",
        status: .active,
        leaderId: "leader-secondary",
        observeId: "observe-secondary",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-secondary",
      workerName: "Worker Secondary"
    )
    let timeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-secondary",
      summary: "Primary cockpit timeline"
    )
    let run = RecordingHarnessClient().codexRunFixture(
      runID: "codex-run-secondary",
      sessionID: summary.sessionId,
      mode: .workspaceWrite,
      status: .running,
      prompt: "Inspect the lane"
    )
    let tui = RecordingHarnessClient().agentTuiFixture(
      tuiID: "agent-tui-secondary",
      sessionID: summary.sessionId,
      runtime: AgentTuiRuntime.codex.rawValue,
      status: .running,
      screenText: "codex> ready"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: timeline],
      detail: detail
    )
    client.configureDetailDelay(.milliseconds(20), for: summary.sessionId)
    client.configureTimelineDelay(.milliseconds(20), for: summary.sessionId)
    client.configureCodexRuns([run], for: summary.sessionId)
    client.configureCodexRunsDelay(.milliseconds(250), for: summary.sessionId)
    client.configureAgentTuis([tui], for: summary.sessionId)
    client.configureAgentTuisDelay(.milliseconds(250), for: summary.sessionId)
    let store = await makeBootstrappedStore(client: client)
    let completionProbe = SessionLoadCompletionProbe()

    let selectionTask = Task { @MainActor in
      await store.selectSession(summary.sessionId)
      await completionProbe.markCompleted()
    }

    try await Task.sleep(for: .milliseconds(80))

    #expect(store.selectedSession?.session.sessionId == summary.sessionId)
    #expect(store.timeline == timeline)
    #expect(store.isSelectionLoading == false)
    #expect(await completionProbe.isCompleted())
    #expect(store.selectedCodexRuns.isEmpty)
    #expect(store.selectedAgentTuis.isEmpty)

    try await Task.sleep(for: .milliseconds(320))

    #expect(store.selectedCodexRuns.map(\.runId) == [run.runId])
    #expect(store.selectedAgentTuis.map(\.tuiId) == [tui.tuiId])

    await selectionTask.value
  }

  @Test("Selecting a new session replaces subscribed session IDs")
  func selectingNewSessionReplacesSubscribedSessionIDs() async {
    let firstSummary = makeSession(
      .init(
        sessionId: "sess-a",
        context: "First cockpit lane",
        status: .active,
        leaderId: "leader-a",
        observeId: "observe-a",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let secondSummary = makeSession(
      .init(
        sessionId: "sess-b",
        context: "Second cockpit lane",
        status: .active,
        leaderId: "leader-b",
        observeId: "observe-b",
        openTaskCount: 0,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [firstSummary, secondSummary],
      detailsByID: [
        firstSummary.sessionId: makeSessionDetail(
          summary: firstSummary,
          workerID: "worker-a",
          workerName: "Worker A"
        ),
        secondSummary.sessionId: makeSessionDetail(
          summary: secondSummary,
          workerID: "worker-b",
          workerName: "Worker B"
        ),
      ],
      detail: makeSessionDetail(
        summary: firstSummary,
        workerID: "worker-a",
        workerName: "Worker A"
      )
    )
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(firstSummary.sessionId)
    #expect(store.subscribedSessionIDs == Set([firstSummary.sessionId]))

    await store.selectSession(secondSummary.sessionId)
    #expect(store.subscribedSessionIDs == Set([secondSummary.sessionId]))
  }
}

private actor SessionLoadCompletionProbe {
  private var completed = false

  func markCompleted() {
    completed = true
  }

  func isCompleted() -> Bool {
    completed
  }
}
