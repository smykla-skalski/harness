import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreSelectionFlowTests {
  @Test("Revisiting a cached session keeps the presented timeline visible during refresh")
  func revisitingCachedSessionKeepsPresentedTimelineVisibleDuringRefresh() async throws {
    let firstSummary = makeSession(
      .init(
        sessionId: "sess-revisit-a",
        context: "First revisit lane",
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
        sessionId: "sess-revisit-b",
        context: "Second revisit lane",
        status: .active,
        leaderId: "leader-b",
        observeId: "observe-b",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
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
    let firstTimeline = makeTimelineEntries(
      sessionID: firstSummary.sessionId,
      agentID: firstDetail.agents[0].agentId,
      summary: "First visible entry"
    )
    let secondTimeline = makeTimelineEntries(
      sessionID: secondSummary.sessionId,
      agentID: secondDetail.agents[0].agentId,
      summary: "Second visible entry"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [firstSummary, secondSummary],
      detailsByID: [
        firstSummary.sessionId: firstDetail,
        secondSummary.sessionId: secondDetail,
      ],
      timelinesBySessionID: [
        firstSummary.sessionId: firstTimeline,
        secondSummary.sessionId: secondTimeline,
      ],
      detail: firstDetail
    )
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: container
    )
    await store.bootstrap()
    await store.cacheSessionDetail(firstDetail, timeline: firstTimeline, markViewed: false)
    await store.selectSession(firstSummary.sessionId)
    await store.selectSession(secondSummary.sessionId)

    client.configureDetailDelay(.milliseconds(250), for: firstSummary.sessionId)
    client.configureTimelineWindowDelay(.milliseconds(250), for: firstSummary.sessionId)

    let revisitTask = Task { await store.selectSession(firstSummary.sessionId) }
    try await Task.sleep(for: .milliseconds(60))

    #expect(store.contentUI.sessionDetail.presentedSessionDetail?.session.sessionId == firstSummary.sessionId)
    #expect(store.contentUI.sessionDetail.presentedTimeline == firstTimeline)
    #expect(store.contentUI.sessionDetail.isTimelineLoading == false)

    await revisitTask.value
  }

  @Test("Cold timeline loads keep the loading placeholder visible for at least 500 ms")
  func coldTimelineLoadsKeepPlaceholderVisibleForMinimumDuration() async throws {
    let client = RecordingHarnessClient()
    client.configureTimelineWindowDelay(.milliseconds(10), for: PreviewFixtures.summary.sessionId)
    let store = await makeBootstrappedStore(client: client)
    let clock = TestTimelineLoadingGateClock()
    store.timelineLoadingGateClock = clock
    store.timelineMinimumLoadingDuration = .milliseconds(500)

    let selectionTask = Task { await store.selectSession(PreviewFixtures.summary.sessionId) }
    try await Task.sleep(for: .milliseconds(80))

    #expect(store.isSelectionLoading == false)
    #expect(store.contentUI.sessionDetail.isTimelineLoading)

    await selectionTask.value
    clock.advance(by: .milliseconds(500))
    await Task.yield()
    await Task.yield()

    #expect(store.contentUI.sessionDetail.isTimelineLoading == false)
  }

  @Test("Cached revisits do not arm the minimum placeholder floor")
  func cachedRevisitsDoNotArmMinimumPlaceholderFloor() async throws {
    let client = RecordingHarnessClient()
    client.configureDetailDelay(.milliseconds(250), for: PreviewFixtures.summary.sessionId)
    client.configureTimelineWindowDelay(.milliseconds(250), for: PreviewFixtures.summary.sessionId)
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: container
    )
    let clock = TestTimelineLoadingGateClock()
    store.timelineLoadingGateClock = clock
    store.timelineMinimumLoadingDuration = .milliseconds(500)
    await store.bootstrap()
    await store.cacheSessionDetail(
      PreviewFixtures.detail,
      timeline: PreviewFixtures.timeline,
      markViewed: false
    )

    let selectionTask = Task { await store.selectSession(PreviewFixtures.summary.sessionId) }
    try await Task.sleep(for: .milliseconds(80))

    #expect(store.contentUI.sessionDetail.isTimelineLoading == false)
    #expect(store.contentUI.sessionDetail.presentedTimeline.count == PreviewFixtures.timeline.count)
    #expect(
      Set(store.contentUI.sessionDetail.presentedTimeline.map(\.entryId))
        == Set(PreviewFixtures.timeline.map(\.entryId))
    )

    clock.advance(by: .milliseconds(500))
    await Task.yield()
    #expect(store.contentUI.sessionDetail.isTimelineLoading == false)

    await selectionTask.value
  }

  @Test("Cached revisit falls back to a bounded latest refresh when the newer delta is incomplete")
  func cachedRevisitFallsBackToBoundedLatestRefreshWhenNewerDeltaIsIncomplete() async throws {
    let summary = makeSession(
      .init(
        sessionId: "cache-revisit-fallback",
        context: "Cached revisit fallback lane",
        status: .active,
        leaderId: "leader-fallback",
        observeId: nil,
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-fallback",
      workerName: "Worker Fallback"
    )
    let fullTimeline = (0..<25).map { index in
      TimelineEntry(
        entryId: "cache-revisit-fallback-\(index)",
        recordedAt: String(format: "2026-04-16T11:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Fallback \(index)",
        payload: .object([:])
      )
    }
    let cachedTimeline = Array(fullTimeline.dropFirst(15))
    let cachedWindow = TimelineWindowResponse.fallbackMetadata(for: cachedTimeline)
    let newestCursor = try #require(cachedWindow.newestCursor)
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: fullTimeline],
      detail: detail
    )
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

    await store.selectSession(summary.sessionId)

    #expect(
      client.recordedTimelineWindowRequests(for: summary.sessionId) == [
        TimelineWindowRequest(
          scope: .summary,
          limit: cachedTimeline.count,
          after: newestCursor
        ),
        .latest(limit: cachedTimeline.count),
      ])
    #expect(store.timeline == Array(fullTimeline.prefix(cachedTimeline.count)))
    #expect(store.timelineWindow?.totalCount == fullTimeline.count)
    #expect(store.timelineWindow?.windowEnd == cachedTimeline.count)
  }
}

@MainActor
private final class TestTimelineLoadingGateClock: TimelineLoadingGateClock {
  private var current = ContinuousClock.now

  var now: ContinuousClock.Instant {
    current
  }

  func sleep(until deadline: ContinuousClock.Instant) async throws {
    while current < deadline {
      try Task.checkCancellation()
      await Task.yield()
    }
  }

  func advance(by duration: Duration) {
    current = current.advanced(by: duration)
  }
}
