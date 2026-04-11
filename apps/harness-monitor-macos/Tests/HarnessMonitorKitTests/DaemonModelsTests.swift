import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Daemon models")
struct DaemonModelsTests {
  @Test("Launch agent lifecycle caption includes stable status parts")
  func launchAgentLifecycleCaptionIncludesStableStatusParts() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      domainTarget: "gui/501",
      serviceTarget: "gui/501/io.harness.daemon",
      state: "running",
      pid: 4_242,
      lastExitStatus: 0
    )

    let caption = status.lifecycleCaption
    #expect(caption.contains("gui/501/io.harness.daemon"))
    #expect(caption.contains("pid 4242"))
    #expect(caption.contains("exit 0"))
  }

  @Test("Launch agent lifecycle title reflects running state with pid")
  func lifecycleTitleRunning() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      pid: 4_242
    )
    #expect(status.lifecycleTitle == "Running")
  }

  @Test("Launch agent lifecycle title reflects loaded state without pid")
  func lifecycleTitleLoaded() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      state: "waiting"
    )
    #expect(status.lifecycleTitle == "Waiting")
  }

  @Test("Launch agent lifecycle title reflects loaded state without state string")
  func lifecycleTitleLoadedNoState() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
    #expect(status.lifecycleTitle == "Loaded")
  }

  @Test("Launch agent lifecycle title reflects installed but not loaded")
  func lifecycleTitleInstalled() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: false,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
    #expect(status.lifecycleTitle == "Installed")
  }

  @Test("Launch agent lifecycle title reflects manual state")
  func lifecycleTitleManual() {
    let status = LaunchAgentStatus(
      installed: false,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
    #expect(status.lifecycleTitle == "Manual")
  }

  @Test("Launch agent lifecycle caption shows status error when present")
  func lifecycleCaptionShowsStatusError() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      statusError: "Could not find service"
    )
    #expect(status.lifecycleCaption == "Could not find service")
  }

  @Test("Launch agent lifecycle caption shows label when service target is empty")
  func lifecycleCaptionFallsBackToLabel() {
    let status = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist",
      state: "waiting"
    )
    #expect(status.lifecycleCaption.contains("io.harness.daemon"))
    #expect(status.lifecycleCaption.contains("waiting"))
  }

  @Test("Daemon diagnostics decode legacy cache payloads")
  func daemonDiagnosticsDecodeLegacyCachePayloads() throws {
    let json = #"""
      {
        "daemon_root": "/Users/example/Library/Application Support/harness/daemon",
        "manifest_path": "/Users/example/Library/Application Support/harness/daemon/manifest.json",
        "auth_token_path": "/Users/example/Library/Application Support/harness/daemon/auth-token",
        "auth_token_present": true,
        "events_path": "/Users/example/Library/Application Support/harness/daemon/events.jsonl",
        "cache_root": "/Users/example/Library/Application Support/harness/daemon/cache/projects",
        "cache_entry_count": 7,
        "last_event": {
          "recorded_at": "2026-04-04T06:39:30Z",
          "level": "info",
          "message": "daemon listening on http://127.0.0.1:63438"
        }
      }
      """#

    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let diagnostics = try decoder.decode(
      DaemonDiagnostics.self,
      from: Data(json.utf8)
    )

    #expect(
      diagnostics.databasePath
        == "/Users/example/Library/Application Support/harness/daemon/harness.db"
    )
    #expect(diagnostics.databaseSizeBytes == 0)
    #expect(diagnostics.lastEvent?.message == "daemon listening on http://127.0.0.1:63438")
  }

  @Test("Bridge status report projects to the manifest shape used by the store")
  func bridgeStatusReportProjectsToHostBridgeManifest() {
    let report = BridgeStatusReport(
      running: true,
      socketPath: "/tmp/bridge.sock",
      pid: 4_242,
      startedAt: "2026-04-11T14:00:00Z",
      uptimeSeconds: 32,
      capabilities: [
        "codex": HostBridgeCapabilityManifest(
          healthy: true,
          transport: "websocket",
          endpoint: "ws://127.0.0.1:4500",
          metadata: ["port": "4500"]
        )
      ]
    )

    #expect(
      report.hostBridgeManifest
        == HostBridgeManifest(
          running: true,
          socketPath: "/tmp/bridge.sock",
          capabilities: [
            "codex": HostBridgeCapabilityManifest(
              healthy: true,
              transport: "websocket",
              endpoint: "ws://127.0.0.1:4500",
              metadata: ["port": "4500"]
            )
          ]
        )
    )
  }

  @Test("Updating daemon status swaps only the host bridge manifest")
  func daemonStatusUpdatingHostBridgePreservesOtherFields() {
    let original = DaemonStatusReport(
      manifest: DaemonManifest(
        version: "19.1.0",
        pid: 4_242,
        endpoint: "http://127.0.0.1:8888",
        startedAt: "2026-04-11T13:00:00Z",
        tokenPath: "/tmp/token",
        sandboxed: true,
        hostBridge: HostBridgeManifest()
      ),
      launchAgent: LaunchAgentStatus(
        installed: true,
        loaded: true,
        label: "io.harness.daemon",
        path: "/tmp/io.harness.daemon.plist"
      ),
      projectCount: 3,
      worktreeCount: 4,
      sessionCount: 5,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/tmp/daemon",
        manifestPath: "/tmp/daemon/manifest.json",
        authTokenPath: "/tmp/daemon/token",
        authTokenPresent: true,
        eventsPath: "/tmp/daemon/events.jsonl",
        databasePath: "/tmp/daemon/harness.db",
        databaseSizeBytes: 123,
        lastEvent: nil
      )
    )

    let updated = original.updating(
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "agent-tui": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "unix",
            endpoint: "/tmp/bridge.sock"
          )
        ]
      )
    )

    #expect(updated.projectCount == 3)
    #expect(updated.worktreeCount == 4)
    #expect(updated.sessionCount == 5)
    #expect(updated.launchAgent == original.launchAgent)
    #expect(updated.diagnostics == original.diagnostics)
    #expect(updated.manifest?.hostBridge.running == true)
    #expect(updated.manifest?.hostBridge.socketPath == "/tmp/bridge.sock")
    #expect(updated.manifest?.hostBridge.capabilities["agent-tui"]?.transport == "unix")
  }
}
