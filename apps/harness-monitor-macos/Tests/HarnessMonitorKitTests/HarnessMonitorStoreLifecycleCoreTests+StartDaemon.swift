import Foundation
import SwiftData
import Testing

@testable import HarnessMonitorKit


@MainActor
extension HarnessMonitorStoreLifecycleCoreTests {
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

  @Test("startDaemon keeps a manifest watcher armed after managed warm-up failure")
  func startDaemonStartsManifestWatcherAfterManagedWarmUpFailure() async {
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
    #expect(store.manifestWatcher != nil)
  }

  @Test("Prepare for termination cancels background work and shuts down the client")
  func prepareForTerminationCancelsBackgroundWorkAndShutsDownClient() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    await store.selectSession(PreviewFixtures.summary.sessionId)
    store.presentSuccessFeedback("Refresh")

    #expect(store.globalStreamTask != nil)
    #expect(store.sessionStreamTask != nil)
    #expect(store.connectionProbeTask != nil)
    #expect(store.currentSuccessFeedbackMessage == "Refresh")

    await store.prepareForTermination()

    #expect(store.client == nil)
    #expect(store.globalStreamTask == nil)
    #expect(store.sessionStreamTask == nil)
    #expect(store.connectionProbeTask == nil)
    #expect(store.currentSuccessFeedbackMessage == nil)
    #expect(client.shutdownCallCount() == 1)
  }

  private struct HydrationSkipFixtures {
    let client: RecordingHarnessClient
    let store: HarnessMonitorStore
    let selectedSummary: SessionSummary
    let backgroundSummary: SessionSummary
    let selectedDetail: SessionDetail
    let backgroundDetail: SessionDetail
    let selectedTimeline: [TimelineEntry]
    let backgroundTimeline: [TimelineEntry]
  }

  private func makeHydrationSkipFixtures() async throws -> HydrationSkipFixtures {
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
