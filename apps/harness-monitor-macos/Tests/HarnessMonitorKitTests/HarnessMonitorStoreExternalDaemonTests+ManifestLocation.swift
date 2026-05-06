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
}
