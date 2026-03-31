import Testing

@testable import HarnessKit

@MainActor
@Suite("Harness store lifecycle")
struct HarnessStoreLifecycleTests {
  @Test("bootstrapIfNeeded only bootstraps once")
  func bootstrapIfNeededOnlyBootstrapsOnce() async {
    let store = HarnessStore(daemonController: RecordingDaemonController())

    await store.bootstrapIfNeeded()
    #expect(store.connectionState == .online)

    store.connectionState = .idle

    await store.bootstrapIfNeeded()
    #expect(store.connectionState == .idle)
  }

  @Test("Start daemon failure sets offline state and error")
  func startDaemonFailureSetsOfflineStateAndError() async {
    let daemon = FailingDaemonController(
      bootstrapError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessStore(daemonController: daemon)

    await store.startDaemon()

    #expect(
      store.connectionState
        == .offline(DaemonControlError.daemonDidNotStart.localizedDescription)
    )
    #expect(store.lastError != nil)
    #expect(store.isDaemonActionInFlight == false)
  }

  @Test("Prime session selection clears detail and timeline")
  func primeSessionSelectionClearsDetailAndTimeline() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    #expect(store.selectedSession != nil)
    #expect(store.timeline.isEmpty == false)

    store.primeSessionSelection("different-session")

    #expect(store.selectedSessionID == "different-session")
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
    #expect(store.isSelectionLoading)
    #expect(store.inspectorSelection == .none)
  }

  @Test("Prime session selection with nil clears everything")
  func primeSessionSelectionWithNilClearsEverything() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)

    store.primeSessionSelection(nil)

    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
    #expect(store.isSelectionLoading == false)
  }

  @Test("Prime session selection with same session is a no-op")
  func primeSessionSelectionWithSameSessionIsNoOp() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    let originalDetail = store.selectedSession

    store.primeSessionSelection(PreviewFixtures.summary.sessionId)

    #expect(store.selectedSession == originalDetail)
    #expect(store.isSelectionLoading == false)
  }

  @Test("Refresh diagnostics without client falls back to daemon status")
  func refreshDiagnosticsWithoutClientFallsBackToDaemonStatus() async {
    let store = HarnessStore(daemonController: RecordingDaemonController())
    store.diagnostics = nil

    await store.refreshDiagnostics()

    #expect(store.diagnostics == nil)
    #expect(store.isDiagnosticsRefreshInFlight == false)
  }

  @Test("Selecting nil session stops session stream subscription")
  func selectingNilSessionStopsSubscription() async {
    let store = await makeBootstrappedStore()
    await store.selectSession(PreviewFixtures.summary.sessionId)
    #expect(store.subscribedSessionIDs.isEmpty == false)

    await store.selectSession(nil)

    #expect(store.subscribedSessionIDs.isEmpty)
    #expect(store.selectedSessionID == nil)
  }

  @Test("Global session update refreshes a non-selected summary without a full refetch")
  func globalSessionUpdateRefreshesNonSelectedSummaryWithoutRefetch() async {
    let client = RecordingHarnessClient()
    let primary = makeSession(.init(
      sessionId: "sess-primary",
      context: "Primary cockpit",
      status: .active,
      leaderId: "leader-primary",
      observeId: "observe-primary",
      openTaskCount: 1,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 1
    ))
    let secondary = makeSession(.init(
      sessionId: "sess-secondary",
      context: "Secondary lane",
      status: .active,
      leaderId: "leader-secondary",
      observeId: nil,
      openTaskCount: 0,
      inProgressTaskCount: 0,
      blockedTaskCount: 0,
      activeAgentCount: 0
    ))
    let updatedSecondary = SessionSummary(
      projectId: secondary.projectId,
      projectName: secondary.projectName,
      projectDir: secondary.projectDir,
      contextRoot: secondary.contextRoot,
      sessionId: secondary.sessionId,
      context: "Secondary lane updated",
      status: .ended,
      createdAt: secondary.createdAt,
      updatedAt: "2026-03-31T12:01:00Z",
      lastActivityAt: "2026-03-31T12:01:00Z",
      leaderId: secondary.leaderId,
      observeId: secondary.observeId,
      pendingLeaderTransfer: secondary.pendingLeaderTransfer,
      metrics: secondary.metrics
    )

    client.configureSessions(
      summaries: [primary, secondary],
      detailsByID: [
        primary.sessionId: makeSessionDetail(
          summary: primary,
          workerID: "worker-primary",
          workerName: "Worker Primary"
        ),
        secondary.sessionId: makeSessionDetail(
          summary: secondary,
          workerID: "worker-secondary",
          workerName: "Worker Secondary"
        ),
      ]
    )
    client.configureGlobalStream(events: [
      .sessionUpdated(
        recordedAt: "2026-03-31T12:01:00Z",
        sessionId: secondary.sessionId,
        detail: makeSessionDetail(
          summary: updatedSecondary,
          workerID: "worker-secondary",
          workerName: "Worker Secondary"
        ),
        timeline: PreviewFixtures.timeline
      )
    ])

    let store = HarnessStore(
      daemonController: RecordingDaemonController(client: client)
    )

    await store.bootstrap()
    await store.selectSession(primary.sessionId)
    let baselineHealthCalls = client.readCallCount(.health)
    try? await Task.sleep(for: .milliseconds(60))

    let updated = store.sessions.first { $0.sessionId == secondary.sessionId }
    #expect(updated?.context == "Secondary lane updated")
    #expect(updated?.status == .ended)
    #expect(store.selectedSession?.session.sessionId == primary.sessionId)
    #expect(client.readCallCount(.health) == baselineHealthCalls)
    #expect(client.readCallCount(.projects) == 1)
    #expect(client.readCallCount(.sessions) == 1)
    #expect(client.readCallCount(.sessionDetail(primary.sessionId)) == 1)

    store.stopAllStreams()
  }
}
