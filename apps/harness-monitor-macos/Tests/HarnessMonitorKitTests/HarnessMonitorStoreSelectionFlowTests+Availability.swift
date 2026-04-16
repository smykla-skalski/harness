import Observation
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreSelectionFlowTests {
  @Test("Session-to-session switch stays on live availability throughout the handoff")
  func sessionToSessionSwitchStaysOnLiveAvailability() async throws {
    let firstSummary = makeSession(
      .init(
        sessionId: "sess-switch-first",
        context: "First cockpit lane",
        status: .active,
        leaderId: "leader-first",
        observeId: "observe-first",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let secondSummary = makeSession(
      .init(
        sessionId: "sess-switch-second",
        context: "Second cockpit lane",
        status: .active,
        leaderId: "leader-second",
        observeId: "observe-second",
        openTaskCount: 0,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let firstDetail = makeSessionDetail(
      summary: firstSummary,
      workerID: "worker-first",
      workerName: "Worker First"
    )
    let secondDetail = makeSessionDetail(
      summary: secondSummary,
      workerID: "worker-second",
      workerName: "Worker Second"
    )
    let firstTimeline = makeTimelineEntries(
      sessionID: firstSummary.sessionId,
      agentID: "worker-first",
      summary: "First timeline"
    )
    let secondTimeline = makeTimelineEntries(
      sessionID: secondSummary.sessionId,
      agentID: "worker-second",
      summary: "Second timeline"
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
    client.configureDetailDelay(.milliseconds(120), for: secondSummary.sessionId)
    client.configureTimelineDelay(.milliseconds(120), for: secondSummary.sessionId)
    let container = try HarnessMonitorModelContainer.preview()
    let daemon = RecordingDaemonController(client: client)
    let store = HarnessMonitorStore(
      daemonController: daemon,
      modelContainer: container
    )
    await store.bootstrap()
    await store.cacheSessionDetail(
      secondDetail,
      timeline: secondTimeline,
      markViewed: false
    )
    await store.selectSession(firstSummary.sessionId)
    #expect(store.sessionDataAvailability == .live)

    let switchTask = Task {
      await store.selectSession(secondSummary.sessionId)
    }
    try await Task.sleep(for: .milliseconds(40))

    #expect(store.selectedSessionID == secondSummary.sessionId)
    #expect(store.selectedSession?.session.sessionId == secondSummary.sessionId)
    #expect(store.isShowingCachedData == false)
    #expect(store.sessionDataAvailability == .live)

    await switchTask.value

    #expect(store.isShowingCachedData == false)
    #expect(store.sessionDataAvailability == .live)
  }
}
