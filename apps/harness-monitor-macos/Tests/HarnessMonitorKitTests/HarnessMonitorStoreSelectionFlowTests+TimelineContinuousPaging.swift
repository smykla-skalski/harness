import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreSelectionFlowTests {
  @Test("Appending older timeline chunks keeps the loaded prefix and grows continuously")
  func appendingOlderTimelineChunksKeepsTheLoadedPrefixAndGrowsContinuously() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-chunk-append",
        context: "Window chunk append lane",
        status: .active,
        leaderId: "leader-window-chunk-append",
        observeId: "observe-window-chunk-append",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-chunk-append",
      workerName: "Window Chunk Worker"
    )
    let fullTimeline = (0..<58).map { index in
      TimelineEntry(
        entryId: "timeline-chunk-append-\(index)",
        recordedAt: String(format: "2026-04-14T07:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Window chunk append \(index)",
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
    let initialWindowSize = HarnessMonitorStoreSelectionTestSupport.initialTimelineWindowSize(
      for: fullTimeline.count
    )
    let firstChunkEnd = min(fullTimeline.count, initialWindowSize + 24)

    await store.selectSession(summary.sessionId)
    let initialPrefix = Array(fullTimeline.prefix(initialWindowSize))
    #expect(store.timeline == initialPrefix)

    await store.appendSelectedTimelineOlderChunk(limit: 24)
    #expect(store.timeline == Array(fullTimeline.prefix(firstChunkEnd)))
    #expect(Array(store.timeline.prefix(initialWindowSize)) == initialPrefix)
    #expect(store.timelineWindow?.windowStart == 0)
    #expect(store.timelineWindow?.windowEnd == firstChunkEnd)
    #expect(store.timelineWindow?.hasNewer == false)
    #expect(store.timelineWindow?.hasOlder == true)

    await store.appendSelectedTimelineOlderChunk(limit: 24)

    #expect(
      client.recordedTimelineWindowRequests(for: summary.sessionId) == [
        .latest(limit: initialWindowSize),
        TimelineWindowRequest(
          scope: .summary,
          limit: 24,
          before: TimelineCursor(
            recordedAt: fullTimeline[initialWindowSize - 1].recordedAt,
            entryId: fullTimeline[initialWindowSize - 1].entryId
          )
        ),
        TimelineWindowRequest(
          scope: .summary,
          limit: fullTimeline.count - firstChunkEnd,
          before: TimelineCursor(
            recordedAt: fullTimeline[firstChunkEnd - 1].recordedAt,
            entryId: fullTimeline[firstChunkEnd - 1].entryId
          )
        ),
      ])
    #expect(store.timeline == fullTimeline)
    #expect(Array(store.timeline.prefix(initialWindowSize)) == initialPrefix)
    #expect(store.timelineWindow?.windowStart == 0)
    #expect(store.timelineWindow?.windowEnd == fullTimeline.count)
    #expect(store.timelineWindow?.hasNewer == false)
    #expect(store.timelineWindow?.hasOlder == false)
  }

  @Test("Appending an older timeline chunk loads only the final partial chunk")
  func appendingOlderTimelineChunkLoadsOnlyTheFinalPartialChunk() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-chunk-no-older",
        context: "Window chunk exhausted lane",
        status: .active,
        leaderId: "leader-window-chunk-no-older",
        observeId: "observe-window-chunk-no-older",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-chunk-no-older",
      workerName: "Window Chunk Exhausted Worker"
    )
    let fullTimeline = (0..<12).map { index in
      TimelineEntry(
        entryId: "timeline-chunk-no-older-\(index)",
        recordedAt: String(format: "2026-04-14T06:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Window chunk exhausted \(index)",
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
    let initialRequestLimit = HarnessMonitorStore.initialSelectedTimelineWindowLimit

    await store.selectSession(summary.sessionId)
    await store.appendSelectedTimelineOlderChunk(limit: 24)

    #expect(
      client.recordedTimelineWindowRequests(for: summary.sessionId) == [
        .latest(limit: initialRequestLimit),
        TimelineWindowRequest(
          scope: .summary,
          limit: fullTimeline.count - initialRequestLimit,
          before: TimelineCursor(
            recordedAt: fullTimeline[initialRequestLimit - 1].recordedAt,
            entryId: fullTimeline[initialRequestLimit - 1].entryId
          )
        ),
      ]
    )
    #expect(store.timeline == fullTimeline)
    #expect(store.timelineWindow?.hasOlder == false)
  }

  @Test("Appending older timeline chunks preserves a middle cursor window")
  func appendingOlderTimelineChunksPreservesMiddleCursorWindow() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-window-middle-chunk",
        context: "Window middle chunk lane",
        status: .active,
        leaderId: "leader-window-middle-chunk",
        observeId: "observe-window-middle-chunk",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-window-middle-chunk",
      workerName: "Window Middle Chunk Worker"
    )
    let fullTimeline = (0..<46).map { index in
      TimelineEntry(
        entryId: "timeline-middle-chunk-\(index)",
        recordedAt: String(format: "2026-04-14T05:%02d:00Z", 59 - index),
        kind: "task_checkpoint",
        sessionId: summary.sessionId,
        agentId: detail.agents[0].agentId,
        taskId: nil,
        summary: "Window middle chunk \(index)",
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
    let middleRequest = TimelineWindowRequest(
      scope: .summary,
      limit: 12,
      before: TimelineCursor(
        recordedAt: fullTimeline[11].recordedAt,
        entryId: fullTimeline[11].entryId
      )
    )

    await store.selectSession(summary.sessionId)
    await store.loadSelectedTimelineWindow(request: middleRequest)
    #expect(store.timeline == Array(fullTimeline[12..<24]))
    #expect(store.timelineWindow?.windowStart == 12)
    #expect(store.timelineWindow?.windowEnd == 24)

    await store.appendSelectedTimelineOlderChunk(limit: 8)

    #expect(store.timeline == Array(fullTimeline[12..<32]))
    #expect(store.timelineWindow?.windowStart == 12)
    #expect(store.timelineWindow?.windowEnd == 32)
    #expect(store.timelineWindow?.hasNewer == true)
    #expect(store.timelineWindow?.hasOlder == true)
  }
}
