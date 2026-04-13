import Observation
import Testing

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
