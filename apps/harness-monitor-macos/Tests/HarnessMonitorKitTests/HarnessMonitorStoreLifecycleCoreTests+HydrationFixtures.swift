import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreLifecycleCoreTests {
  struct HydrationSkipFixtures {
    let client: RecordingHarnessClient
    let store: HarnessMonitorStore
    let selectedSummary: SessionSummary
    let backgroundSummary: SessionSummary
    let selectedDetail: SessionDetail
    let backgroundDetail: SessionDetail
    let selectedTimeline: [TimelineEntry]
    let backgroundTimeline: [TimelineEntry]
  }

  func makeHydrationSkipFixtures() async throws -> HydrationSkipFixtures {
    let selectedSummary = makeSession(
      .init(
        sessionId: "sess-selected-hydration",
        context: "Selected hydration",
        status: .active,
        leaderId: "leader-selected-hydration",
        observeId: nil,
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 2
      )
    )
    let backgroundSummary = makeSession(
      .init(
        sessionId: "sess-background-hydration",
        context: "Background hydration",
        status: .active,
        leaderId: "leader-background-hydration",
        observeId: nil,
        openTaskCount: 0,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        activeAgentCount: 2,
        lastActivityAt: "2026-03-28T14:17:00Z"
      )
    )
    let selectedDetail = makeSessionDetail(
      summary: selectedSummary,
      workerID: "worker-selected-hydration",
      workerName: "Worker Selected Hydration"
    )
    let backgroundDetail = makeSessionDetail(
      summary: backgroundSummary,
      workerID: "worker-background-hydration",
      workerName: "Worker Background Hydration"
    )
    let selectedTimeline = makeTimelineEntries(
      sessionID: selectedSummary.sessionId,
      agentID: "worker-selected-hydration",
      summary: "Selected hydration timeline"
    )
    let backgroundTimeline = makeTimelineEntries(
      sessionID: backgroundSummary.sessionId,
      agentID: "worker-background-hydration",
      summary: "Background hydration timeline"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [selectedSummary, backgroundSummary],
      detailsByID: [
        selectedSummary.sessionId: selectedDetail,
        backgroundSummary.sessionId: backgroundDetail,
      ],
      timelinesBySessionID: [
        selectedSummary.sessionId: selectedTimeline,
        backgroundSummary.sessionId: backgroundTimeline,
      ],
      detail: selectedDetail
    )
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: RecordingDaemonController(client: client),
      modelContainer: container
    )
    await store.bootstrap()
    store.activeTransport = .webSocket
    await store.selectSession(selectedSummary.sessionId)
    await store.cacheSessionDetail(selectedDetail, timeline: selectedTimeline)
    await store.cacheSessionDetail(backgroundDetail, timeline: [])
    return HydrationSkipFixtures(
      client: client,
      store: store,
      selectedSummary: selectedSummary,
      backgroundSummary: backgroundSummary,
      selectedDetail: selectedDetail,
      backgroundDetail: backgroundDetail,
      selectedTimeline: selectedTimeline,
      backgroundTimeline: backgroundTimeline
    )
  }
}
