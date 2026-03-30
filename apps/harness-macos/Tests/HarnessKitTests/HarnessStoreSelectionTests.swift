import Observation
import Testing

@testable import HarnessKit

@MainActor
@Suite("Harness store selection")
struct HarnessStoreSelectionTests {
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
    #expect(!store.isBusy)
    #expect(!store.isDaemonActionInFlight)
    #expect(!store.isSessionActionInFlight)

    await refreshTask.value

    #expect(!store.isDiagnosticsRefreshInFlight)
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
    let client = configuredSelectionClient(
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
    #expect(!store.isSelectionLoading)
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
    let client = configuredSelectionClient(
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

  @Test("Reconnect restores the selected session stream subscription")
  func reconnectRestoresSelectedSessionStreamSubscription() async {
    let summary = makeSession(
      .init(
        sessionId: "sess-reconnect",
        context: "Reconnect lane",
        status: .active,
        leaderId: "leader-reconnect",
        observeId: "observe-reconnect",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-reconnect",
      workerName: "Worker Reconnect"
    )
    let client = configuredSelectionClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      detail: detail
    )
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(summary.sessionId)
    #expect(store.subscribedSessionIDs == Set([summary.sessionId]))

    await store.reconnect()

    #expect(store.selectedSessionID == summary.sessionId)
    #expect(store.subscribedSessionIDs == Set([summary.sessionId]))
  }

  @Test("Selected task observation tracks inspector selection changes")
  func selectedTaskObservationTracksInspectorSelectionChanges() async throws {
    let store = await makeBootstrappedStore()

    await store.selectSession(PreviewFixtures.summary.sessionId)

    await confirmation("selected task observation fired") { confirm in
      _ = withObservationTracking(
        {
          store.selectedTask?.taskId
        },
        onChange: {
          confirm()
        }
      )

      store.inspect(taskID: "task-ui")
    }

    #expect(store.selectedTask?.taskId == "task-ui")
  }

  private func configuredSelectionClient(
    summaries: [SessionSummary],
    detailsByID: [String: SessionDetail],
    timelinesBySessionID: [String: [TimelineEntry]] = [:],
    detail: SessionDetail
  ) -> RecordingHarnessClient {
    let client = RecordingHarnessClient(detail: detail)
    client.configureSessions(
      summaries: summaries,
      detailsByID: detailsByID,
      timelinesBySessionID: timelinesBySessionID
    )
    return client
  }
}
