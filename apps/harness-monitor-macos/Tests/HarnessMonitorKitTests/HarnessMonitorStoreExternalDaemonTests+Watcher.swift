import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreExternalDaemonTests {
  @Test("Manifest watcher fires connectionChange when startedAt changes")
  func manifestWatcherFiresWhenStartedAtChanges() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-monitor-watcher-\(UUID().uuidString)", isDirectory: true)
    let daemonDir =
      tempRoot
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("daemon", isDirectory: true)
    try FileManager.default.createDirectory(
      at: daemonDir,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: tempRoot)
    }

    let environment = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: tempRoot.path
      ]
    )

    let manifestURL = HarnessMonitorPaths.manifestURL(using: environment)
    let initialPayload =
      ManifestWatcherTestPayloads.daemonManifest(
        endpoint: "http://127.0.0.1:8765",
        startedAt: "2026-04-11T12:00:00Z",
        revision: 1,
        hostBridgeRunning: false
      )
    try initialPayload.write(to: manifestURL, atomically: true, encoding: .utf8)

    let recorder = ManifestChangeRecorder()
    let watcher = ManifestWatcher(
      environment: environment,
      currentEndpoint: "http://127.0.0.1:8765",
      currentStartedAt: "2026-04-11T12:00:00Z",
      currentRevision: 1
    ) { change in
      recorder.record(change)
    }
    watcher.start()
    defer { watcher.stop() }

    try await Task.sleep(for: .milliseconds(150))

    let tmpURL = daemonDir.appendingPathComponent("manifest.json.tmp")
    let updatedPayload =
      ManifestWatcherTestPayloads.daemonManifest(
        endpoint: "http://127.0.0.1:8765",
        startedAt: "2026-04-11T12:05:00Z",
        revision: 2,
        hostBridgeRunning: false
      )
    try updatedPayload.write(to: tmpURL, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: manifestURL)
    try FileManager.default.moveItem(at: tmpURL, to: manifestURL)

    var fired = false
    for _ in 0..<20 {
      if !recorder.isEmpty {
        fired = true
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(fired, "ManifestWatcher did not fire after startedAt changed")

    let changes = recorder.snapshot
    if case .connectionChange? = changes.first {
      // expected
    } else {
      Issue.record(
        "Expected .connectionChange when startedAt moved, got \(String(describing: changes.first))"
      )
    }
  }

  @Test("Manifest watcher fires inPlaceUpdate when only revision changes")
  func manifestWatcherFiresInPlaceUpdateWhenRevisionBumps() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-monitor-watcher-\(UUID().uuidString)", isDirectory: true)
    let daemonDir =
      tempRoot
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("daemon", isDirectory: true)
    try FileManager.default.createDirectory(
      at: daemonDir,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: tempRoot)
    }

    let environment = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: tempRoot.path
      ]
    )

    let manifestURL = HarnessMonitorPaths.manifestURL(using: environment)
    // Seed the file on disk matching the watcher's initial state so the
    // first fs-event fires only because we then bump the revision.
    let initial = ManifestWatcherTestPayloads.daemonManifest(
      endpoint: "http://127.0.0.1:8765",
      startedAt: "2026-04-11T12:00:00Z",
      revision: 1,
      hostBridgeRunning: false
    )
    try initial.write(to: manifestURL, atomically: true, encoding: .utf8)

    let recorder = ManifestChangeRecorder()
    let watcher = ManifestWatcher(
      environment: environment,
      currentEndpoint: "http://127.0.0.1:8765",
      currentStartedAt: "2026-04-11T12:00:00Z",
      currentRevision: 1
    ) { change in
      recorder.record(change)
    }
    watcher.start()
    defer { watcher.stop() }

    try await Task.sleep(for: .milliseconds(150))

    // Rewrite the manifest with the same endpoint/startedAt but bump
    // revision and flip host_bridge.running to true.
    let tmpURL = daemonDir.appendingPathComponent("manifest.json.tmp")
    let updated = ManifestWatcherTestPayloads.daemonManifest(
      endpoint: "http://127.0.0.1:8765",
      startedAt: "2026-04-11T12:00:00Z",
      revision: 2,
      hostBridgeRunning: true
    )
    try updated.write(to: tmpURL, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: manifestURL)
    try FileManager.default.moveItem(at: tmpURL, to: manifestURL)

    var fired = false
    for _ in 0..<20 {
      if !recorder.isEmpty {
        fired = true
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(fired, "ManifestWatcher did not fire after revision bump")

    let changes = recorder.snapshot
    if case .inPlaceUpdate(let manifest)? = changes.first {
      #expect(manifest.revision == 2)
      #expect(manifest.hostBridge.running == true)
    } else {
      Issue.record(
        "Expected .inPlaceUpdate when only revision moved, got \(String(describing: changes.first))"
      )
    }
  }

  @Test("Manifest watcher ignores rewrites that keep all three tracked fields stable")
  func manifestWatcherIgnoresRewritesThatKeepFieldsStable() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-monitor-watcher-\(UUID().uuidString)", isDirectory: true)
    let daemonDir =
      tempRoot
      .appendingPathComponent("harness", isDirectory: true)
      .appendingPathComponent("daemon", isDirectory: true)
    try FileManager.default.createDirectory(
      at: daemonDir,
      withIntermediateDirectories: true
    )
    defer {
      try? FileManager.default.removeItem(at: tempRoot)
    }

    let environment = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: tempRoot.path
      ]
    )

    let manifestURL = HarnessMonitorPaths.manifestURL(using: environment)
    // Seed the watcher's initial state and the on-disk manifest to match.
    let seed = ManifestWatcherTestPayloads.daemonManifest(
      endpoint: "http://127.0.0.1:8765",
      startedAt: "2026-04-11T12:00:00Z",
      revision: 1,
      hostBridgeRunning: false
    )
    try seed.write(to: manifestURL, atomically: true, encoding: .utf8)

    let recorder = ManifestChangeRecorder()
    let watcher = ManifestWatcher(
      environment: environment,
      currentEndpoint: "http://127.0.0.1:8765",
      currentStartedAt: "2026-04-11T12:00:00Z",
      currentRevision: 1
    ) { change in
      recorder.record(change)
    }
    watcher.start()
    defer { watcher.stop() }

    try await Task.sleep(for: .milliseconds(150))

    // Rewrite the manifest with byte-identical contents (same endpoint,
    // startedAt and revision). Even though the fs event fires, the watcher
    // must not emit a ManifestChange because none of the three tracked
    // fields moved.
    let tmpURL = daemonDir.appendingPathComponent("manifest.json.tmp")
    try seed.write(to: tmpURL, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: manifestURL)
    try FileManager.default.moveItem(at: tmpURL, to: manifestURL)

    // Give the dispatch source time to fire and be dropped.
    try await Task.sleep(for: .milliseconds(500))

    #expect(
      recorder.isEmpty,
      "ManifestWatcher should stay silent when endpoint/startedAt/revision are unchanged"
    )
  }

  @Test("applyManifestRevision refreshes hostBridge and clears stale issues")
  func applyManifestRevisionRefreshesHostBridgeAndClearsIssues() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .managed
    )

    await store.bootstrap()
    // Seed a sandboxed daemonStatus with an empty host bridge, then stamp
    // a stale issue as if a prior 503 had been recorded.
    let sandboxedManifest = DaemonManifest(
      version: "19.5.2",
      pid: 1,
      endpoint: "http://127.0.0.1:0",
      startedAt: "2026-04-11T12:00:00Z",
      tokenPath: "/tmp/token",
      sandboxed: true,
      hostBridge: HostBridgeManifest(),
      revision: 1
    )
    let seededLaunchAgent = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
    store.daemonStatus = DaemonStatusReport(
      manifest: sandboxedManifest,
      launchAgent: seededLaunchAgent,
      projectCount: 0,
      sessionCount: 0,
      diagnostics: DaemonDiagnostics(
        daemonRoot: "/tmp",
        manifestPath: "/tmp/manifest.json",
        authTokenPath: "/tmp/auth-token",
        authTokenPresent: true,
        eventsPath: "/tmp/events.jsonl",
        databasePath: "/tmp/harness.db",
        databaseSizeBytes: 0,
        lastEvent: nil
      )
    )
    store.markHostBridgeIssue(for: "agent-tui", statusCode: 503)
    #expect(store.hostBridgeCapabilityState(for: "agent-tui") == .unavailable)

    let refreshed = DaemonManifest(
      version: "19.5.2",
      pid: 1,
      endpoint: "http://127.0.0.1:0",
      startedAt: "2026-04-11T12:00:00Z",
      tokenPath: "/tmp/token",
      sandboxed: true,
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
      ),
      revision: 2
    )
    store.applyManifestRevision(refreshed)

    #expect(store.daemonStatus?.manifest?.hostBridge.running == true)
    #expect(store.daemonStatus?.manifest?.hostBridge.capabilities["agent-tui"] != nil)
    #expect(store.hostBridgeCapabilityState(for: "agent-tui") == .ready)
    #expect(store.hostBridgeCapabilityIssues.isEmpty)
    // Sanity: launch agent state is preserved, not overwritten.
    #expect(store.daemonStatus?.launchAgent.installed == true)
    #expect(store.daemonStatus?.launchAgent.label == "io.harness.daemon")
  }

  @Test("applyManifestRevision preserves launch agent, counts, and diagnostics")
  func applyManifestRevisionPreservesLaunchAgentAndCounts() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .managed
    )
    await store.bootstrap()

    let sandboxedManifest = DaemonManifest(
      version: "19.6.0",
      pid: 1,
      endpoint: "http://127.0.0.1:0",
      startedAt: "2026-04-11T12:00:00Z",
      tokenPath: "/tmp/token",
      sandboxed: true,
      hostBridge: HostBridgeManifest(),
      revision: 1
    )
    let seededLaunchAgent = LaunchAgentStatus(
      installed: true,
      loaded: true,
      label: "io.harness.daemon",
      path: "/tmp/io.harness.daemon.plist"
    )
    let seededDiagnostics = DaemonDiagnostics(
      daemonRoot: "/tmp",
      manifestPath: "/tmp/manifest.json",
      authTokenPath: "/tmp/auth-token",
      authTokenPresent: true,
      eventsPath: "/tmp/events.jsonl",
      databasePath: "/tmp/harness.db",
      databaseSizeBytes: 512,
      lastEvent: DaemonAuditEvent(
        recordedAt: "2026-04-11T12:00:00Z",
        level: "info",
        message: "daemon booted"
      )
    )
    store.daemonStatus = DaemonStatusReport(
      manifest: sandboxedManifest,
      launchAgent: seededLaunchAgent,
      projectCount: 7,
      worktreeCount: 3,
      sessionCount: 42,
      diagnostics: seededDiagnostics
    )

    let refreshed = DaemonManifest(
      version: "19.6.0",
      pid: 1,
      endpoint: "http://127.0.0.1:0",
      startedAt: "2026-04-11T12:00:00Z",
      tokenPath: "/tmp/token",
      sandboxed: true,
      hostBridge: HostBridgeManifest(running: true),
      revision: 2
    )
    store.applyManifestRevision(refreshed)

    // hostBridge flipped.
    #expect(store.daemonStatus?.manifest?.hostBridge.running == true)
    // Everything else is exactly the same.
    #expect(store.daemonStatus?.launchAgent == seededLaunchAgent)
    #expect(store.daemonStatus?.projectCount == 7)
    #expect(store.daemonStatus?.worktreeCount == 3)
    #expect(store.daemonStatus?.sessionCount == 42)
    #expect(store.daemonStatus?.diagnostics == seededDiagnostics)
  }

  @Test("applyManifestRevision is a no-op when daemonStatus is nil")
  func applyManifestRevisionIsNoopWhenDaemonStatusIsNil() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: false,
      registrationState: .notRegistered,
      warmUpError: DaemonControlError.externalDaemonOffline(manifestPath: "/tmp/manifest.json")
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )
    await store.bootstrap()
    store.daemonStatus = nil

    let manifest = DaemonManifest(
      version: "19.5.2",
      pid: 1,
      endpoint: "http://127.0.0.1:0",
      startedAt: "2026-04-11T12:00:00Z",
      tokenPath: "/tmp/token",
      sandboxed: true,
      hostBridge: HostBridgeManifest(running: true),
      revision: 9
    )
    store.applyManifestRevision(manifest)

    #expect(store.daemonStatus == nil)
  }
}
