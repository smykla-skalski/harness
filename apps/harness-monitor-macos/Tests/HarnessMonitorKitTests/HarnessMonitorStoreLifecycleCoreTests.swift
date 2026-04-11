import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store lifecycle core")
struct HarnessMonitorStoreLifecycleCoreTests {
  @Test("API client shutdown invalidates the backing URLSession")
  func apiClientShutdownInvalidatesSession() async {
    let probe = SessionInvalidationProbe()
    let session = URLSession(
      configuration: .ephemeral,
      delegate: probe,
      delegateQueue: nil
    )
    let client = HarnessMonitorAPIClient(
      connection: HarnessMonitorConnection(
        endpoint: URL(string: "http://127.0.0.1:9999")!,
        token: "token"
      ),
      session: session
    )

    await client.shutdown()

    for _ in 0..<20 where !probe.didInvalidate {
      try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(probe.didInvalidate)
  }

  @Test("bootstrapIfNeeded only bootstraps once")
  func bootstrapIfNeededOnlyBootstrapsOnce() async {
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())

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
    let store = HarnessMonitorStore(daemonController: daemon)

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
    let store = HarnessMonitorStore(daemonController: RecordingDaemonController())
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
    #expect(store.contentUI.shell.selectedSessionID == selectedSummary.sessionId)

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
    #expect(store.contentUI.shell.selectedSessionID == nil)
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

  @Test("startDaemon registers the launch agent when notRegistered then connects")
  func startDaemonRegistersWhenNotRegisteredThenConnects() async {
    let daemon = RecordingDaemonController(launchAgentInstalled: false)
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    #expect(store.connectionState == .online)
  }

  @Test("startDaemon with requiresApproval marks offline without warming up")
  func startDaemonWithRequiresApprovalMarksOffline() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .requiresApproval,
      warmUpError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    if case .offline(let reason) = store.connectionState {
      #expect(reason.contains("approval"))
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
  }

  @Test("startDaemon with enabled agent connects via awaitManifestWarmUp")
  func startDaemonWithEnabledAgentConnects() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    #expect(store.connectionState == .online)
  }

  @Test("startDaemon surfaces awaitManifestWarmUp failure as offline")
  func startDaemonSurfacesWarmUpFailureAsOffline() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled,
      warmUpError: DaemonControlError.daemonDidNotStart
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    if case .offline = store.connectionState {
      // expected
    } else {
      Issue.record("expected offline state, got \(store.connectionState)")
    }
  }

  @Test("startDaemon refreshes the managed launch agent after stale warm-up failure")
  func startDaemonRefreshesManagedLaunchAgentAfterWarmUpFailure() async {
    let daemon = ManagedWarmUpRecoveryDaemonController()
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.startDaemon()

    #expect(store.connectionState == .online)
    #expect(await daemon.recordedOperations() == ["warm-up", "remove", "register", "warm-up"])
  }

  @Test("Prepare for termination cancels background work and shuts down the client")
  func prepareForTerminationCancelsBackgroundWorkAndShutsDownClient() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.showLastAction("Refresh")

    #expect(store.globalStreamTask != nil)
    #expect(store.sessionStreamTask != nil)
    #expect(store.connectionProbeTask != nil)
    #expect(store.lastAction == "Refresh")

    await store.prepareForTermination()

    #expect(store.client == nil)
    #expect(store.globalStreamTask == nil)
    #expect(store.sessionStreamTask == nil)
    #expect(store.connectionProbeTask == nil)
    #expect(store.lastAction.isEmpty)
    #expect(client.shutdownCallCount() == 1)
  }
}

actor ManagedWarmUpRecoveryDaemonController: DaemonControlling {
  private let client: any HarnessMonitorClientProtocol
  private var warmUpAttempts = 0
  private var operations: [String] = []

  init(client: any HarnessMonitorClientProtocol = PreviewHarnessClient()) {
    self.client = client
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
        version: "19.4.0",
        pid: 111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-04-11T14:00:00Z",
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
    operations.append("remove")
    return "launch agent removed"
  }

  func registerLaunchAgent() async throws -> DaemonLaunchAgentRegistrationState {
    operations.append("register")
    return .enabled
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
    operations.append("warm-up")
    if warmUpAttempts == 0 {
      warmUpAttempts += 1
      throw DaemonControlError.daemonDidNotStart
    }
    return client
  }

  func recordedOperations() -> [String] {
    operations
  }
}
