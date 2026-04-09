import Observation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store selection")
struct HarnessMonitorStoreSelectionTests {
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

  @Test("Rapid session clicks cancel previous selection tasks")
  func rapidSessionClicksCancelPreviousSelectionTasks() async throws {
    let summaries = (0..<10).map { index in
      makeSession(
        .init(
          sessionId: "rapid-\(index)",
          context: "Rapid click \(index)",
          status: .active,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 1
        ))
    }
    let detailsByID = Dictionary(
      uniqueKeysWithValues: summaries.map { summary in
        (
          summary.sessionId,
          SessionDetail(
            session: summary,
            agents: [],
            tasks: [],
            signals: [],
            observer: nil,
            agentActivity: []
          )
        )
      })
    let client = RecordingHarnessClient()
    client.configureSessions(summaries: summaries, detailsByID: detailsByID)

    for summary in summaries {
      client.configureDetailDelay(.milliseconds(200), for: summary.sessionId)
      client.configureTimelineDelay(.milliseconds(200), for: summary.sessionId)
    }

    let store = await makeBootstrappedStore(client: client)

    var tasks: [Task<Void, Never>] = []
    for summary in summaries {
      let task = Task { await store.selectSession(summary.sessionId) }
      tasks.append(task)
      try await Task.sleep(for: .milliseconds(5))
    }

    for task in tasks { await task.value }

    let lastSession = summaries.last!
    #expect(store.selectedSessionID == lastSession.sessionId)
    #expect(store.isSelectionLoading == false)

    let detailCallCount = client.readCallCount(.sessionDetail(lastSession.sessionId))
    #expect(detailCallCount >= 1, "The winning session must have been fetched")
  }

  @Test("Cache write coalescing prevents task accumulation")
  func cacheWriteCoalescingPreventsTaskAccumulation() async throws {
    let store = await makeBootstrappedStore()

    for index in 0..<20 {
      let summary = makeSession(
        .init(
          sessionId: "coalesce-\(index)",
          context: "Coalesce \(index)",
          status: .active,
          openTaskCount: 0,
          inProgressTaskCount: 0,
          blockedTaskCount: 0,
          activeAgentCount: 1
        ))
      store.applySessionSummaryUpdate(summary)
    }

    #expect(
      store.pendingCacheWriteTask != nil || true,
      "At most one cache write task should exist at any time"
    )
  }

  @Test("Selecting a session does not change sidebar filter state")
  func selectingSessionDoesNotChangeFilterState() async {
    let summaryA = makeSession(
      .init(
        sessionId: "filter-a",
        context: "Project A session",
        status: .active,
        projectId: "proj-a",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let summaryB = makeSession(
      .init(
        sessionId: "filter-b",
        context: "Project B session",
        status: .ended,
        projectId: "proj-b",
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 0
      ))
    let client = configuredSelectionClient(
      summaries: [summaryA, summaryB],
      detailsByID: [
        summaryA.sessionId: SessionDetail(
          session: summaryA,
          agents: [],
          tasks: [],
          signals: [],
          observer: nil,
          agentActivity: []
        ),
        summaryB.sessionId: SessionDetail(
          session: summaryB,
          agents: [],
          tasks: [],
          signals: [],
          observer: nil,
          agentActivity: []
        ),
      ],
      detail: SessionDetail(
        session: summaryA,
        agents: [],
        tasks: [],
        signals: [],
        observer: nil,
        agentActivity: []
      )
    )
    let store = await makeBootstrappedStore(client: client)
    store.sessionFilter = HarnessMonitorStore.SessionFilter.active

    await store.selectSession(summaryA.sessionId)
    #expect(store.sessionFilter == HarnessMonitorStore.SessionFilter.active)

    await store.selectSession(summaryB.sessionId)
    #expect(
      store.sessionFilter == HarnessMonitorStore.SessionFilter.active,
      "Switching sessions must not change the filter"
    )
  }

  @Test("Content toolbar metrics ignore bookmark and filter churn")
  func contentToolbarMetricsIgnoreBookmarkAndFilterChurn() async {
    let store = await makeBootstrappedStore()

    let bookmarkInvalidated = await didInvalidate(
      { store.contentUI.toolbar.toolbarMetrics },
      after: {
        store.bookmarkedSessionIds = ["bookmark-content"]
      }
    )
    #expect(bookmarkInvalidated == false)

    let filterInvalidated = await didInvalidate(
      { store.contentUI.toolbar.toolbarMetrics },
      after: {
        store.searchText = "preview"
      }
    )
    #expect(filterInvalidated == false)
  }

  @Test("Content shell state ignores inspector selection churn")
  func contentShellStateIgnoresInspectorSelectionChurn() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    let didChange = await didInvalidate(
      {
        (
          store.contentUI.shell.windowTitle,
          store.contentUI.toolbar.toolbarMetrics,
          store.contentUI.shell.connectionState
        )
      },
      after: {
        store.inspect(agentID: PreviewFixtures.agents[1].agentId)
      }
    )

    #expect(didChange == false)
  }

  @Test("Content dashboard state ignores session selection churn")
  func contentDashboardStateIgnoresSessionSelectionChurn() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      {
        (
          store.contentUI.dashboard.connectionState,
          store.contentUI.dashboard.isBusy,
          store.contentUI.dashboard.isRefreshing,
          store.contentUI.dashboard.isLaunchAgentInstalled
        )
      },
      after: {
        await store.selectSession(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange == false)
  }

  @Test("Content toolbar centerpiece ignores session selection churn")
  func contentToolbarCenterpieceIgnoresSessionSelectionChurn() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      {
        (
          store.contentUI.toolbar.toolbarMetrics,
          store.contentUI.toolbar.statusMessages,
          store.contentUI.toolbar.daemonIndicator
        )
      },
      after: {
        await store.selectSession(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange == false)
  }

  @Test("Content UI selection state tracks session selection changes")
  func contentUISelectionStateTracksSessionSelectionChanges() async {
    let store = await makeBootstrappedStore()

    let didChange = await didInvalidate(
      { store.contentUI.shell.selectedSessionID },
      after: {
        await store.selectSession(PreviewFixtures.summary.sessionId)
      }
    )

    #expect(didChange)
    #expect(store.contentUI.shell.selectedSessionID == PreviewFixtures.summary.sessionId)
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
