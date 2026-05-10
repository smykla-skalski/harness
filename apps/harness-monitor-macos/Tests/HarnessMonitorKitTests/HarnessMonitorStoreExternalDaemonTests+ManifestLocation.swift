import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreExternalDaemonTests {
  @Test("External bootstrap adopts the live diagnostics manifest path")
  func externalBootstrapAdoptsResolvedManifestPath() async {
    let manifestPath = "/tmp/runtime-lanes/copilot-relaunch/harness/daemon/manifest.json"
    let daemonRoot = URL(fileURLWithPath: manifestPath)
      .deletingLastPathComponent()
      .path
    let tokenPath = "\(daemonRoot)/auth-token"
    let client = RecordingHarnessClient()
    client.projectSummariesStorage = []
    client.sessionSummariesStorage = []
    client.diagnosticsReportOverride = DaemonDiagnosticsReport(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 1_111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 0,
        worktreeCount: 0,
        sessionCount: 0
      ),
      manifest: DaemonManifest(
        version: "14.5.0",
        pid: 1_111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        tokenPath: tokenPath
      ),
      launchAgent: LaunchAgentStatus(
        installed: false,
        loaded: false,
        label: "io.harnessmonitor.daemon",
        path: "/tmp/io.harnessmonitor.daemon.plist",
        domainTarget: "gui/501",
        serviceTarget: "gui/501/io.harnessmonitor.daemon"
      ),
      workspace: DaemonDiagnostics(
        daemonRoot: daemonRoot,
        manifestPath: manifestPath,
        authTokenPath: tokenPath,
        authTokenPresent: true,
        eventsPath: "\(daemonRoot)/events.jsonl",
        databasePath: "\(daemonRoot)/harness.db",
        databaseSizeBytes: 4_096,
        lastEvent: nil
      ),
      recentEvents: []
    )

    let daemon = RecordingDaemonController(
      client: client,
      launchAgentInstalled: false,
      registrationState: .notRegistered
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(store.manifestURL.path == manifestPath)
  }

  @Test("External bootstrap rediscovers a manifest that appears after startup failure")
  func externalBootstrapRediscoversManifestAfterStartupFailure() async throws {
    let staleManifestPath = "/tmp/harness/daemon/manifest.json"
    let liveManifestPath = "/tmp/runtime-lanes/late-start/harness/daemon/manifest.json"
    let liveDaemonRoot = URL(fileURLWithPath: liveManifestPath).deletingLastPathComponent().path
    let liveTokenPath = "\(liveDaemonRoot)/auth-token"

    let client = RecordingHarnessClient()
    client.projectSummariesStorage = []
    client.sessionSummariesStorage = []
    client.diagnosticsReportOverride = DaemonDiagnosticsReport(
      health: HealthResponse(
        status: "ok",
        version: "14.5.0",
        pid: 1_111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        projectCount: 0,
        worktreeCount: 0,
        sessionCount: 0
      ),
      manifest: DaemonManifest(
        version: "14.5.0",
        pid: 1_111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        tokenPath: liveTokenPath
      ),
      launchAgent: LaunchAgentStatus(
        installed: false,
        loaded: false,
        label: "io.harnessmonitor.daemon",
        path: "/tmp/io.harnessmonitor.daemon.plist",
        domainTarget: "gui/501",
        serviceTarget: "gui/501/io.harnessmonitor.daemon"
      ),
      workspace: DaemonDiagnostics(
        daemonRoot: liveDaemonRoot,
        manifestPath: liveManifestPath,
        authTokenPath: liveTokenPath,
        authTokenPresent: true,
        eventsPath: "\(liveDaemonRoot)/events.jsonl",
        databasePath: "\(liveDaemonRoot)/harness.db",
        databaseSizeBytes: 4_096,
        lastEvent: nil
      ),
      recentEvents: []
    )

    let daemon = RediscoveringExternalDaemonController(
      client: client,
      staleManifestPath: staleManifestPath
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )
    store.externalManifestDiscoveryInterval = .milliseconds(20)

    await store.bootstrap()

    guard case .offline = store.connectionState else {
      Issue.record("Expected offline connection state after the initial bootstrap failure")
      return
    }

    await daemon.publishLiveManifest(at: liveManifestPath)

    var becameOnline = false
    for _ in 0..<40 {
      if case .online = store.connectionState {
        becameOnline = true
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }

    #expect(becameOnline)
    #expect(store.manifestURL.path == liveManifestPath)
    #expect(await daemon.recordedWarmUpCallCount() >= 2)
    #expect(
      store.connectionEvents.contains { event in
        event.detail == "Discovered live external daemon manifest, re-bootstrapping"
      }
    )
  }
}

private actor RediscoveringExternalDaemonController: DaemonControlling,
  ExternalManifestLocationRefreshing
{
  private let client: any HarnessMonitorClientProtocol
  private let staleManifestPath: String
  private var liveManifestURL: URL?
  private var activeManifestPath: String
  private var warmUpCallCount = 0

  init(
    client: any HarnessMonitorClientProtocol,
    staleManifestPath: String
  ) {
    self.client = client
    self.staleManifestPath = staleManifestPath
    activeManifestPath = staleManifestPath
  }

  func bootstrapClient() async throws -> any HarnessMonitorClientProtocol {
    try await awaitManifestWarmUp(timeout: .seconds(0))
  }

  func stopDaemon() async throws -> String {
    "stopped"
  }

  func daemonStatus() async throws -> DaemonStatusReport {
    let manifestPath = activeManifestPath
    let daemonRoot = URL(fileURLWithPath: manifestPath).deletingLastPathComponent().path
    let tokenPath = "\(daemonRoot)/auth-token"
    return DaemonStatusReport(
      manifest: DaemonManifest(
        version: "14.5.0",
        pid: 1_111,
        endpoint: "http://127.0.0.1:9999",
        startedAt: "2026-03-28T14:00:00Z",
        tokenPath: tokenPath
      ),
      launchAgent: LaunchAgentStatus(
        installed: false,
        loaded: false,
        label: "io.harnessmonitor.daemon",
        path: "/tmp/io.harnessmonitor.daemon.plist",
        domainTarget: "gui/501",
        serviceTarget: "gui/501/io.harnessmonitor.daemon"
      ),
      projectCount: 0,
      sessionCount: 0,
      diagnostics: DaemonDiagnostics(
        daemonRoot: daemonRoot,
        manifestPath: manifestPath,
        authTokenPath: tokenPath,
        authTokenPresent: true,
        eventsPath: "\(daemonRoot)/events.jsonl",
        databasePath: "\(daemonRoot)/harness.db",
        databaseSizeBytes: 0,
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
    .notRegistered
  }

  func repairLaunchAgentRegistration() async throws -> String {
    "launch agent re-registered"
  }

  func launchAgentRegistrationState() async -> DaemonLaunchAgentRegistrationState {
    .notRegistered
  }

  func launchAgentSnapshot() async -> LaunchAgentStatus {
    LaunchAgentStatus(
      installed: false,
      loaded: false,
      label: "io.harnessmonitor.daemon",
      path: "/tmp/io.harnessmonitor.daemon.plist",
      domainTarget: "gui/501",
      serviceTarget: "gui/501/io.harnessmonitor.daemon"
    )
  }

  func awaitLaunchAgentState(
    _ target: DaemonLaunchAgentRegistrationState,
    timeout: Duration
  ) async throws {}

  func awaitManifestWarmUp(
    timeout: Duration
  ) async throws -> any HarnessMonitorClientProtocol {
    warmUpCallCount += 1
    guard activeManifestPath != staleManifestPath else {
      throw DaemonControlError.externalDaemonOffline(manifestPath: staleManifestPath)
    }
    return client
  }

  func performDeferredManagedLaunchAgentRefreshIfNeeded() async -> Bool {
    false
  }

  func refreshExternalManifestLocation() async -> URL? {
    guard let liveManifestURL else {
      return nil
    }
    guard activeManifestPath != liveManifestURL.path else {
      return nil
    }
    activeManifestPath = liveManifestURL.path
    return liveManifestURL
  }

  func publishLiveManifest(at path: String) {
    liveManifestURL = URL(fileURLWithPath: path)
  }

  func recordedWarmUpCallCount() -> Int {
    warmUpCallCount
  }
}
