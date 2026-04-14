import Foundation
import Testing

@testable import HarnessMonitorKit

private func makeSandboxedStatus(hostBridge: HostBridgeManifest) -> DaemonStatusReport {
  DaemonStatusReport(
    manifest: DaemonManifest(
      version: "19.8.1",
      pid: 111,
      endpoint: "http://127.0.0.1:9999",
      startedAt: "2026-04-12T09:00:00Z",
      tokenPath: "/tmp/token",
      sandboxed: true,
      hostBridge: hostBridge
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

@MainActor
@Suite("Harness Monitor bridge refresh")
struct HarnessMonitorStoreBridgeRefreshTests {
  // MARK: - Baseline

  @Test("applyManifestRevision updates host bridge when running transitions to true")
  func applyManifestRevisionUpdatesBridgeState() async {
    let store = await makeBootstrappedStore()
    store.daemonStatus = makeSandboxedStatus(hostBridge: HostBridgeManifest())
    store.hostBridgeCapabilityIssues["codex"] = .unavailable

    let updatedManifest = DaemonManifest(
      version: "19.8.1",
      pid: 42,
      endpoint: "http://127.0.0.1:9999",
      startedAt: "2026-04-12T10:00:00Z",
      tokenPath: "/tmp/auth-token",
      sandboxed: true,
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "codex": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "websocket",
            endpoint: "ws://127.0.0.1:4500"
          )
        ]
      ),
      revision: 1
    )

    store.applyManifestRevision(updatedManifest)

    #expect(store.codexUnavailable == false)
  }

  // MARK: - refreshBridgeStateFromManifest

  @Test("refreshBridgeStateFromManifest clears unavailable when bridge starts running")
  func refreshBridgeStateFromManifestClearsUnavailableWhenBridgeRunning() async throws {
    let store = await makeBootstrappedStore()
    store.daemonStatus = makeSandboxedStatus(hostBridge: HostBridgeManifest())
    store.hostBridgeCapabilityIssues["codex"] = .unavailable

    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("bridge-refresh-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let manifestURL = tempDir.appendingPathComponent("manifest.json")
    let manifest = DaemonManifest(
      version: "19.8.1",
      pid: 42,
      endpoint: "http://127.0.0.1:9999",
      startedAt: "2026-04-12T10:00:00Z",
      tokenPath: "/tmp/auth-token",
      sandboxed: true,
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "codex": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "websocket",
            endpoint: "ws://127.0.0.1:4500"
          )
        ]
      ),
      revision: 1
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(manifest)
    try data.write(to: manifestURL)

    await store.refreshBridgeStateFromManifest(at: manifestURL)

    #expect(store.codexUnavailable == false)
  }

  @Test("refreshBridgeStateFromManifest is no-op when bridge state is unchanged")
  func refreshBridgeStateFromManifestIsNoopWhenBridgeUnchanged() async throws {
    let store = await makeBootstrappedStore()
    store.daemonStatus = makeSandboxedStatus(hostBridge: HostBridgeManifest())
    store.hostBridgeCapabilityIssues["codex"] = .unavailable
    let eventCountBefore = store.connectionEvents.count

    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("bridge-noop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let manifestURL = tempDir.appendingPathComponent("manifest.json")
    let manifest = DaemonManifest(
      version: "19.8.1",
      pid: 42,
      endpoint: "http://127.0.0.1:9999",
      startedAt: "2026-04-12T10:00:00Z",
      tokenPath: "/tmp/auth-token",
      sandboxed: true,
      hostBridge: HostBridgeManifest(),
      revision: 0
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(manifest)
    try data.write(to: manifestURL)

    await store.refreshBridgeStateFromManifest(at: manifestURL)

    #expect(store.codexUnavailable == true)
    #expect(store.connectionEvents.count == eventCountBefore)
  }

  @Test("refreshBridgeStateFromManifest records malformed manifest errors")
  func refreshBridgeStateFromManifestRecordsMalformedManifestErrors() async throws {
    let store = await makeBootstrappedStore()
    store.daemonStatus = makeSandboxedStatus(hostBridge: HostBridgeManifest())
    let eventCountBefore = store.connectionEvents.count

    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("bridge-malformed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let manifestURL = tempDir.appendingPathComponent("manifest.json")
    try Data("{ not valid json".utf8).write(to: manifestURL)

    await store.refreshBridgeStateFromManifest(at: manifestURL)

    #expect(store.codexUnavailable == true)
    #expect(store.connectionEvents.count == eventCountBefore + 1)
    #expect(store.connectionEvents.last?.kind == .error)
    let lastDetail = store.connectionEvents.last?.detail ?? ""
    #expect(lastDetail.contains("Failed to decode daemon manifest") == true)
  }

  @Test("Connection probe uses the store cached manifest URL for bridge refresh")
  func connectionProbeUsesCachedManifestURLForBridgeRefresh() async throws {
    let client = RecordingHarnessClient()
    client.configureTransportLatencyMs(11)
    let store = await makeBootstrappedStore(client: client)
    store.daemonStatus = makeSandboxedStatus(hostBridge: HostBridgeManifest())
    store.hostBridgeCapabilityIssues["codex"] = .unavailable
    store.connectionProbeInterval = .milliseconds(30)

    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("bridge-probe-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let manifestURL = tempDir.appendingPathComponent("manifest.json")
    let manifest = DaemonManifest(
      version: "19.8.1",
      pid: 42,
      endpoint: "http://127.0.0.1:9999",
      startedAt: "2026-04-12T10:00:00Z",
      tokenPath: "/tmp/auth-token",
      sandboxed: true,
      hostBridge: HostBridgeManifest(
        running: true,
        socketPath: "/tmp/bridge.sock",
        capabilities: [
          "codex": HostBridgeCapabilityManifest(
            healthy: true,
            transport: "websocket",
            endpoint: "ws://127.0.0.1:4500"
          )
        ]
      ),
      revision: 1
    )
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    try encoder.encode(manifest).write(to: manifestURL)

    store.manifestURL = manifestURL

    try await Task.sleep(for: .milliseconds(120))

    #expect(store.codexUnavailable == false)
    #expect(client.readCallCount(.transportLatency) > 0)

    store.stopAllStreams()
  }
}
