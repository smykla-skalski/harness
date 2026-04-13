import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreLifecycleCoreTests {
  @Test("Refresh skips selected session during persisted snapshot hydration")
  func refreshSkipsSelectedSessionDuringPersistedSnapshotHydration() async throws {
    let fixtures = try await makeHydrationSkipFixtures()
    let client = fixtures.client
    let store = fixtures.store
    let selectedSummary = fixtures.selectedSummary
    let backgroundSummary = fixtures.backgroundSummary
    let selectedTimeline = fixtures.selectedTimeline
    let backgroundTimeline = fixtures.backgroundTimeline

    let updatedSelectedSummary = makeUpdatedSession(
      selectedSummary,
      context: "Selected hydration updated",
      updatedAt: "2026-03-28T15:10:00Z",
      agentCount: 2
    )
    let updatedBackgroundSummary = makeUpdatedSession(
      backgroundSummary,
      context: "Background hydration updated",
      updatedAt: "2026-03-28T15:11:00Z",
      agentCount: 2
    )
    let updatedSelectedDetail = makeSessionDetail(
      summary: updatedSelectedSummary,
      workerID: "worker-selected-hydration",
      workerName: "Worker Selected Hydration"
    )
    let updatedBackgroundDetail = makeSessionDetail(
      summary: updatedBackgroundSummary,
      workerID: "worker-background-hydration",
      workerName: "Worker Background Hydration"
    )

    client.configureSessions(
      summaries: [updatedSelectedSummary, updatedBackgroundSummary],
      detailsByID: [
        updatedSelectedSummary.sessionId: updatedSelectedDetail,
        updatedBackgroundSummary.sessionId: updatedBackgroundDetail,
      ],
      timelinesBySessionID: [
        updatedSelectedSummary.sessionId: selectedTimeline,
        updatedBackgroundSummary.sessionId: backgroundTimeline,
      ]
    )
    client.configureDetailDelay(.milliseconds(200), for: selectedSummary.sessionId)

    let baselineSelectedDetailCount = client.readCallCount(
      .sessionDetail(selectedSummary.sessionId))
    let baselineSelectedTimelineCount = client.readCallCount(.timeline(selectedSummary.sessionId))
    let baselineBackgroundDetailCount = client.readCallCount(
      .sessionDetail(backgroundSummary.sessionId))
    let baselineBackgroundTimelineCount = client.readCallCount(
      .timeline(backgroundSummary.sessionId))

    await store.refresh(using: client, preserveSelection: true)
    try? await Task.sleep(for: .milliseconds(40))

    #expect(
      client.readCallCount(.sessionDetail(backgroundSummary.sessionId))
        == baselineBackgroundDetailCount)
    #expect(
      client.readCallCount(.timeline(backgroundSummary.sessionId))
        == baselineBackgroundTimelineCount)

    for _ in 0..<50 {
      let selectedTimelineCount = client.readCallCount(.timeline(selectedSummary.sessionId))
      let backgroundTimelineCount = client.readCallCount(.timeline(backgroundSummary.sessionId))
      if selectedTimelineCount > baselineSelectedTimelineCount
        && backgroundTimelineCount > baselineBackgroundTimelineCount
      {
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(
      client.readCallCount(.sessionDetail(selectedSummary.sessionId)) == baselineSelectedDetailCount
        + 1)
    #expect(
      client.readCallCount(.timeline(selectedSummary.sessionId)) == baselineSelectedTimelineCount
        + 1)
    #expect(
      client.readCallCount(.sessionDetail(backgroundSummary.sessionId))
        == baselineBackgroundDetailCount + 1)
    #expect(
      client.readCallCount(.timeline(backgroundSummary.sessionId))
        == baselineBackgroundTimelineCount + 1)
    #expect(client.sessionDetailScopes(for: selectedSummary.sessionId).last == "core")
    #expect(client.sessionDetailScopes(for: backgroundSummary.sessionId).last == "core")
  }

  @Test("Replacing the session snapshot clears removed selection across UI slices")
  func replacingSessionSnapshotClearsRemovedSelectionAcrossUISlices() async {
    let selectedSummary = makeSession(
      .init(
        sessionId: "sess-selected",
        context: "Selected cockpit",
        status: .active,
        leaderId: "leader-selected",
        observeId: "observe-selected",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1
      )
    )
    let selectedDetail = makeSessionDetail(
      summary: selectedSummary,
      workerID: "worker-selected",
      workerName: "Worker Selected"
    )
    let selectedTimeline = makeTimelineEntries(
      sessionID: selectedSummary.sessionId,
      agentID: "worker-selected",
      summary: "Selected timeline"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [selectedSummary],
      detailsByID: [selectedSummary.sessionId: selectedDetail],
      timelinesBySessionID: [selectedSummary.sessionId: selectedTimeline],
      detail: selectedDetail
    )
    let store = await makeBootstrappedStore(client: client)

    await store.selectSession(selectedSummary.sessionId)
    #expect(store.sidebarUI.selectedSessionID == selectedSummary.sessionId)
    #expect(store.contentUI.session.selectedSessionSummary == selectedSummary)

    let replacementSummary = makeSession(
      .init(
        sessionId: "sess-replacement",
        context: "Replacement cockpit",
        status: .active,
        leaderId: "leader-replacement",
        observeId: "observe-replacement",
        openTaskCount: 0,
        inProgressTaskCount: 1,
        blockedTaskCount: 0,
        activeAgentCount: 1,
        lastActivityAt: "2026-03-28T14:19:00Z"
      )
    )

    store.applySessionIndexSnapshot(
      projects: [makeProject(totalSessionCount: 1, activeSessionCount: 1)],
      sessions: [replacementSummary]
    )

    #expect(store.selectedSessionID == nil)
    #expect(store.selectedSession == nil)
    #expect(store.timeline.isEmpty)
    #expect(store.subscribedSessionIDs.isEmpty)
    #expect(store.sidebarUI.selectedSessionID == nil)
    #expect(store.contentUI.session.selectedSessionSummary == nil)
  }

  @Test("Bootstrap with notRegistered agent marks offline and sets installed false")
  func bootstrapWithNotRegisteredAgentMarksOffline() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: false,
      registrationState: .notRegistered
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    if case .offline(let reason) = store.connectionState {
      #expect(reason.contains("not installed"))
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
    #expect(store.daemonStatus?.launchAgent.installed == false)
  }

  @Test("Bootstrap with requiresApproval marks offline with approval message")
  func bootstrapWithRequiresApprovalMarksOffline() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .requiresApproval
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    if case .offline(let reason) = store.connectionState {
      #expect(reason.contains("approval"))
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
  }

  @Test("Bootstrap with enabled state connects via awaitManifestWarmUp")
  func bootstrapWithEnabledStateConnects() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    #expect(store.connectionState == .online)
  }

  @Test("Bootstrap surfaces awaitManifestWarmUp failure as offline")
  func bootstrapSurfacesWarmUpFailureAsOffline() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled,
      warmUpError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    if case .offline = store.connectionState {
      // expected
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
  }

  @Test("Bootstrap refreshes the managed launch agent after stale warm-up failure")
  func bootstrapRefreshesManagedLaunchAgentAfterWarmUpFailure() async {
    let daemon = ManagedWarmUpRecoveryDaemonController()
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(await daemon.recordedOperations() == ["warm-up", "remove", "register", "warm-up"])
  }

  @Test("Managed bootstrap restores cached state before warm-up completes")
  func managedBootstrapRestoresCachedStateBeforeWarmUpCompletes() async throws {
    let summary = makeSession(
      .init(
        sessionId: "sess-cached-bootstrap",
        context: "Cached bootstrap session",
        status: .active,
        leaderId: "leader-cached-bootstrap",
        observeId: "observe-cached-bootstrap",
        openTaskCount: 1,
        inProgressTaskCount: 0,
        blockedTaskCount: 0,
        activeAgentCount: 1,
        lastActivityAt: "2026-04-13T20:59:00Z"
      )
    )
    let detail = makeSessionDetail(
      summary: summary,
      workerID: "worker-cached-bootstrap",
      workerName: "Worker Cached Bootstrap"
    )
    let timeline = makeTimelineEntries(
      sessionID: summary.sessionId,
      agentID: "worker-cached-bootstrap",
      summary: "Cached bootstrap timeline"
    )
    let client = HarnessMonitorStoreSelectionTestSupport.configuredClient(
      summaries: [summary],
      detailsByID: [summary.sessionId: detail],
      timelinesBySessionID: [summary.sessionId: timeline],
      detail: detail
    )
    let daemon = DelayedWarmUpDaemonController(
      client: client,
      warmUpDelay: .milliseconds(250)
    )
    let container = try HarnessMonitorModelContainer.preview()
    let store = HarnessMonitorStore(
      daemonController: daemon,
      modelContainer: container
    )

    await store.cacheSessionList(
      [summary],
      projects: [makeProject(totalSessionCount: 1, activeSessionCount: 1)]
    )
    await store.cacheSessionDetail(detail, timeline: timeline)
    store.primeSessionSelection(summary.sessionId)

    let bootstrapTask = Task { @MainActor in
      await store.bootstrap()
    }

    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.connectionState == .connecting)
    #expect(store.sessions.map(\.sessionId) == [summary.sessionId])
    #expect(store.selectedSession?.session.sessionId == summary.sessionId)
    #expect(store.timeline == timeline)
    #expect(store.isShowingCachedData)

    await bootstrapTask.value
    #expect(store.connectionState == .online)
  }

  @Test("Bootstrap keeps a manifest watcher armed after managed warm-up failure")
  func bootstrapStartsManifestWatcherAfterManagedWarmUpFailure() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled,
      warmUpError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    if case .offline = store.connectionState {
      // expected
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
    #expect(store.manifestWatcher != nil)
    #expect(
      store.connectionEvents.contains { event in
        event.detail.contains(
          "Managed daemon did not become healthy; refreshing the bundled launch agent")
      }
    )
  }

}

actor DelayedWarmUpDaemonController: DaemonControlling {
  private let client: any HarnessMonitorClientProtocol
  private let warmUpDelay: Duration

  init(
    client: any HarnessMonitorClientProtocol = PreviewHarnessClient(),
    warmUpDelay: Duration
  ) {
    self.client = client
    self.warmUpDelay = warmUpDelay
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    client
  }

  func stopDaemon() async throws -> String {
    "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: DaemonManifest(
        version: "20.6.10",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-04-13T20:58:00Z",
        tokenPath: "/tmp/token"
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        loaded: true,
        label: "io.harness.daemon",
        path: "/tmp/io.harness.daemon.plist"
      ),
      projectCount: 1,
      sessionCount: 1,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/tmp/harness/daemon",
        manifestPath: "/tmp/harness/daemon/manifest.json",
        authTokenPath: "/tmp/token",
        authTokenPresent: true,
        eventsPath: "/tmp/harness/daemon/events.jsonl",
        databasePath: "/tmp/harness/daemon/harness.db",
        databaseSizeBytes: 1_024,
        lastEvent: nil
      )
    )
  }

  func installLaunchAgent() async throws -> String {
    "launch agent installed"
  }

  func removeLaunchAgent() async throws -> String {
    "launch agent removed"
  }

  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    .enabled
  }

  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState {
    .enabled
  }

  func launchAgentSnapshot() async -> LaunchAgentStatus {
    LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
  }

  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws {}

  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    try await Task.sleep(for: warmUpDelay)
    return client
  }
}
