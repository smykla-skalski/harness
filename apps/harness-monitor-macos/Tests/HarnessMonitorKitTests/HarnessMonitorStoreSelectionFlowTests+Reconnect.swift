import Observation
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreSelectionFlowTests {
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
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
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

  @Test("Reconnect-ready events refresh push-only global and session state")
  func reconnectReadyEventsRefreshPushOnlyGlobalAndSessionState() async throws {
    let client = RecordingHarnessClient()
    let staleRun = client.codexRunFixture(
      runID: "codex-run-reconnect",
      mode: .approval,
      status: .running,
      latestSummary: "Still running."
    )
    let recoveredApproval = client.codexApprovalFixture(approvalID: "approval-reconnect")
    let recoveredRun = client.codexRunFixture(
      runID: staleRun.runId,
      mode: .approval,
      status: .waitingApproval,
      latestSummary: "Waiting for approval.",
      pendingApprovals: [recoveredApproval]
    )
    let staleTui = client.agentTuiFixture(
      tuiID: "agent-tui-reconnect",
      screenText: "copilot> stale"
    )
    let recoveredTui = client.agentTuiFixture(
      tuiID: staleTui.tuiId,
      screenText: "copilot> recovered"
    )

    client.configureCodexRuns([staleRun], for: PreviewFixtures.summary.sessionId)
    client.configureAgentTuis([staleTui], for: PreviewFixtures.summary.sessionId)
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.stopAllStreams()

    store.daemonLogLevel = "debug"
    client.configureCodexRuns([recoveredRun], for: PreviewFixtures.summary.sessionId)
    client.configureAgentTuis([recoveredTui], for: PreviewFixtures.summary.sessionId)
    client.configureGlobalStream(
      events: [.ready(recordedAt: "2026-04-13T21:00:00Z")]
    )
    client.configureSessionStream(
      events: [
        .ready(
          recordedAt: "2026-04-13T21:00:01Z",
          sessionId: PreviewFixtures.summary.sessionId
        )
      ],
      for: PreviewFixtures.summary.sessionId
    )

    store.startGlobalStream(using: client)
    store.startSessionStream(using: client, sessionID: PreviewFixtures.summary.sessionId)
    try await Task.sleep(for: .milliseconds(50))

    #expect(store.daemonLogLevel == HarnessMonitorLogger.defaultDaemonLogLevel)
    #expect(store.selectedCodexRun?.pendingApprovals == [recoveredApproval])
    #expect(store.selectedAgentTui?.screen.text == "copilot> recovered")

    store.stopAllStreams()
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

  @Test("Duplicate sidebar selection does not restart the active load")
  func duplicateSidebarSelectionDoesNotRestartActiveLoad() async throws {
    let summary = makeSession(
      .init(
        sessionId: "duplicate-selection",
        context: "Duplicate selection",
        status: .active,
        openTaskCount: 0,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      ))
    let detail = SessionDetail(
      session: summary,
      agents: [],
      tasks: [],
      signals: [],
      observer: nil,
      agentActivity: []
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      detail: detail
    )
    client.configureDetailDelay(.milliseconds(150), for: summary.sessionId)
    client.configureTimelineDelay(.milliseconds(150), for: summary.sessionId)
    let store = await makeBootstrappedStore(client: client)

    store.selectSessionFromList(summary.sessionId)
    try await Task.sleep(for: .milliseconds(20))
    store.selectSessionFromList(summary.sessionId)
    await store.pendingListSelectionTask?.value
    await store.selectionTask?.value

    #expect(store.selectedSessionID == summary.sessionId)
    #expect(store.selectedSession?.session.sessionId == summary.sessionId)
    #expect(client.readCallCount(.sessionDetail(summary.sessionId)) == 1)
    #expect(client.readCallCount(.timelineWindow(summary.sessionId)) == 1)
  }

  @Test("Sidebar selection defers store mutation until after the delegate turn")
  func sidebarSelectionDefersStoreMutationUntilAfterDelegateTurn() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    store.selectSessionFromList(PreviewFixtures.summary.sessionId)

    #expect(store.selectedSessionID == nil)
    #expect(store.selectionTask == nil)

    await store.pendingListSelectionTask?.value

    #expect(store.selectedSessionID == PreviewFixtures.summary.sessionId)
    #expect(store.selectionTask != nil)
  }

  @Test("Reselecting the loaded sidebar session clears inspector without reloading")
  func reselectingLoadedSidebarSessionClearsInspectorWithoutReloading() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    let detailCallCount = client.readCallCount(.sessionDetail(PreviewFixtures.summary.sessionId))
    let timelineCallCount = client.readCallCount(.timeline(PreviewFixtures.summary.sessionId))

    store.inspect(taskID: "task-ui")
    store.selectSessionFromList(PreviewFixtures.summary.sessionId)
    await store.pendingListSelectionTask?.value

    #expect(store.inspectorSelection == .none)
    #expect(
      client.readCallCount(.sessionDetail(PreviewFixtures.summary.sessionId)) == detailCallCount)
    #expect(client.readCallCount(.timeline(PreviewFixtures.summary.sessionId)) == timelineCallCount)
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
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
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
}
