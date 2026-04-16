import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreSelectionFlowTests {
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

    #expect(
      client.recordedTimelineWindowRequests(for: summary.sessionId) == [
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

  @Test("Loading the same timeline page while it is already in flight coalesces requests")
  func loadingSameTimelinePageWhileInFlightCoalescesRequests() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-page-coalesce",
        context: "Window coalescing lane",
        status: .active,
        leaderId: "leader-window-page-coalesce",
        observeId: "observe-window-page-coalesce",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-page-coalesce",
      workerName: "Window Coalescing Worker"
    )
    let fullTimeline = (0..<25).map { index in
      TimelineEntry(
        entryId: "timeline-page-coalesce-\(index)",
        recordedAt: String(format: "2026-04-14T10:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Window coalescing \(index)",
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
    client.configureTimelineWindowDelay(.milliseconds(250), for: summary.sessionId)

    async let firstLoad: Void = store.loadSelectedTimelinePage(page: 1, pageSize: 10)
    async let secondLoad: Void = store.loadSelectedTimelinePage(page: 1, pageSize: 10)
    await firstLoad
    await secondLoad

    #expect(
      client.recordedTimelineWindowRequests(for: summary.sessionId) == [
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

    #expect(
      client.recordedTimelineWindowRequests(for: summary.sessionId) == [
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

    #expect(
      client.recordedTimelineWindowRequests(for: summary.sessionId) == [
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
}
