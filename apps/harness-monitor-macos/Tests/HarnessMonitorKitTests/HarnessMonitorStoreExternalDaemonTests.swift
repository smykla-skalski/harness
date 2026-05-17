import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor store external daemon")
struct HarnessMonitorStoreExternalDaemonTests {
  @Test("External bootstrap skips launch agent gate and connects via warm-up")
  func externalBootstrapSkipsLaunchAgentAndConnects() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: false,
      registrationState: .notRegistered
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )

    await store.bootstrap()

    #expect(store.connectionState == .online)
    #expect(store.currentFailureFeedbackMessage == nil)
  }

  @Test("External bootstrap reports short external offline error")
  func externalBootstrapReportsExternalOfflineError() async {
    let manifestPath = "/tmp/harness/daemon/manifest.json"
    let daemon = RecordingDaemonController(
      warmUpError: DaemonControlError.externalDaemonOffline(manifestPath: manifestPath)
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )

    await store.bootstrap()

    guard case .offline(let message) = store.connectionState else {
      Issue.record("Expected offline connection state, got \(store.connectionState)")
      return
    }
    #expect(message == "Background helper is not running. Start it to load live sessions.")
  }

  @Test("Managed bootstrap still gates on launch agent registration state")
  func managedBootstrapGatesOnRegistrationState() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: false,
      registrationState: .requiresApproval
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    guard case .offline(let message) = store.connectionState else {
      Issue.record("Expected offline connection state, got \(store.connectionState)")
      return
    }
    #expect(message.contains("approval"))
  }

  @Test("External bootstrap falls through to warm-up error when warm-up fails")
  func externalBootstrapFallsBackToWarmUpErrorMessage() async {
    struct SentinelError: Error, LocalizedError {
      var errorDescription: String? { "sentinel warm-up failure" }
    }
    let daemon = RecordingDaemonController(warmUpError: SentinelError())
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )

    await store.bootstrap()

    guard case .offline(let message) = store.connectionState else {
      Issue.record("Expected offline connection state, got \(store.connectionState)")
      return
    }
    // Non-DaemonControlError falls back to the generic recovery guidance message.
    #expect(message.contains("Background helper unavailable"))
  }

  @Test("Ownership init reads HARNESS_MONITOR_EXTERNAL_DAEMON")
  func ownershipInitReadsEnvironmentFlag() {
    #expect(DaemonOwnership(environment: [:]) == .managed)
    #expect(
      DaemonOwnership(environment: [DaemonOwnership.environmentKey: "1"])
        == .external
    )
    #expect(
      DaemonOwnership(environment: [DaemonOwnership.environmentKey: "true"])
        == .external
    )
    #expect(
      DaemonOwnership(environment: [DaemonOwnership.environmentKey: "external"])
        == .external
    )
    #expect(
      DaemonOwnership(environment: [DaemonOwnership.environmentKey: "0"])
        == .managed
    )
    #expect(
      DaemonOwnership(environment: [DaemonOwnership.environmentKey: "false"])
        == .managed
    )
    #expect(
      DaemonOwnership(environment: [DaemonOwnership.environmentKey: "managed"])
        == .managed
    )
  }

  @Test("Ownership reads persisted startup preference")
  func ownershipReadsPersistedStartupPreference() throws {
    let suiteName = "io.harnessmonitor.tests.daemon-ownership.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    #expect(DaemonOwnership.persistedPreference(defaults: defaults) == nil)

    defaults.set(DaemonOwnership.external.rawValue, forKey: DaemonOwnership.preferenceKey)
    #expect(DaemonOwnership.persistedPreference(defaults: defaults) == .external)

    defaults.set(DaemonOwnership.managed.rawValue, forKey: DaemonOwnership.preferenceKey)
    #expect(DaemonOwnership.persistedPreference(defaults: defaults) == .managed)
  }

  @Test("External daemon offline error uses short user-facing copy")
  func externalDaemonOfflineErrorMessageUsesShortCopy() {
    let error = DaemonControlError.externalDaemonOffline(manifestPath: "/tmp/x")
    let description = error.errorDescription ?? ""
    #expect(description == "Background helper is not running. Start it to load live sessions.")
    #expect(!description.contains("/tmp/x"))
  }

  @Test("Stale manifest error message uses short user-facing copy")
  func staleManifestErrorHasDistinctWording() {
    let error = DaemonControlError.externalDaemonManifestStale(
      manifestPath: "/tmp/y/manifest.json"
    )
    let description = error.errorDescription ?? ""
    #expect(description == "Background helper stopped unexpectedly. Restart it to reconnect.")
    #expect(!description.contains("/tmp/y/manifest.json"))
  }

  @Test("External bootstrap surfaces stale manifest recovery when warm-up throws it")
  func externalBootstrapSurfacesStaleManifestError() async {
    let daemon = RecordingDaemonController(
      warmUpError: DaemonControlError.externalDaemonManifestStale(
        manifestPath: "/tmp/stale/manifest.json"
      )
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )

    await store.bootstrap()

    guard case .offline(let message) = store.connectionState else {
      Issue.record("Expected offline connection state, got \(store.connectionState)")
      return
    }
    #expect(message == "Background helper stopped. Restart it to reconnect.")
  }

  @Test("External bootstrap warns when SMAppService launch agent is still registered")
  func externalBootstrapWarnsWhenSMAppServiceRegistered() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: true,
      registrationState: .enabled
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )

    await store.bootstrap()

    let warnings = store.connectionEvents.filter { event in
      event.detail.contains("SMAppService launch agent is still registered")
    }
    #expect(warnings.isEmpty == false)
    let warning = warnings.first
    #expect(warning?.kind == .error)
    #expect(warning?.detail.contains("harness daemon dev") == true)
  }

  @Test("External bootstrap without SMAppService does not emit conflict warning")
  func externalBootstrapDoesNotWarnWhenSMAppServiceMissing() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: false,
      registrationState: .notRegistered
    )
    let store = HarnessMonitorStore(
      daemonController: daemon,
      daemonOwnership: .external
    )

    await store.bootstrap()

    let warnings = store.connectionEvents.filter { event in
      event.detail.contains("SMAppService launch agent is still registered")
    }
    #expect(warnings.isEmpty)
  }

  @Test("installLaunchAgent throws in external daemon mode")
  func installLaunchAgentThrowsInExternalMode() async {
    let controller = DaemonController(
      launchAgentManager: FakeLaunchAgentManager(state: .notRegistered),
      ownership: .external
    )
    var caught: (any Error)?
    do {
      _ = try await controller.installLaunchAgent()
    } catch {
      caught = error
    }
    guard case .commandFailed(let message) = caught as? DaemonControlError else {
      Issue.record("Expected commandFailed, got \(String(describing: caught))")
      return
    }
    #expect(message.contains("external daemon mode"))
  }

  @Test("removeLaunchAgent throws in external daemon mode")
  func removeLaunchAgentThrowsInExternalMode() async {
    let controller = DaemonController(
      launchAgentManager: FakeLaunchAgentManager(state: .enabled),
      ownership: .external
    )
    var caught: (any Error)?
    do {
      _ = try await controller.removeLaunchAgent()
    } catch {
      caught = error
    }
    guard case .commandFailed(let message) = caught as? DaemonControlError else {
      Issue.record("Expected commandFailed, got \(String(describing: caught))")
      return
    }
    #expect(message.contains("external daemon mode"))
  }

  @Test("installLaunchAgent still runs in managed daemon mode")
  func installLaunchAgentStillRunsInManagedMode() async throws {
    let controller = DaemonController(
      launchAgentManager: FakeLaunchAgentManager(state: .enabled),
      ownership: .managed
    )
    let response = try await controller.installLaunchAgent()
    #expect(response.contains("already installed"))
  }

  @Test("Manifest watcher fires connectionChange on first manifest write")
  func manifestWatcherFiresOnFirstWrite() async throws {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-monitor-watcher-\(UUID().uuidString)", isDirectory: true)
    defer {
      try? FileManager.default.removeItem(at: tempRoot)
    }

    let environment = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey: tempRoot.path
      ]
    )

    let manifestURL = HarnessMonitorPaths.manifestURL(using: environment)
    let daemonDir = HarnessMonitorPaths.daemonRoot(using: environment)
    try FileManager.default.createDirectory(
      at: daemonDir,
      withIntermediateDirectories: true
    )
    #expect(manifestURL.path.hasPrefix(tempRoot.path))

    let recorder = ManifestChangeRecorder()
    let watcher = ManifestWatcher(
      environment: environment,
      currentEndpoint: ""
    ) { change in
      recorder.record(change)
    }
    watcher.start()
    defer { watcher.stop() }

    // Let the DispatchSource finish attaching before the write.
    try await Task.sleep(for: .milliseconds(150))

    // Mimic the daemon's atomic tmp-file + rename write path. Must be a
    // full DaemonManifest payload so the watcher's decoder succeeds.
    let tmpURL = daemonDir.appendingPathComponent("manifest.json.tmp")
    let payload =
      ManifestWatcherTestPayloads.daemonManifest(
        endpoint: "http://127.0.0.1:8765",
        startedAt: "2026-04-11T12:00:00Z",
        revision: 1,
        hostBridgeRunning: false
      )
    try payload.write(to: tmpURL, atomically: true, encoding: .utf8)
    try FileManager.default.moveItem(at: tmpURL, to: manifestURL)

    // Poll briefly; the dispatch source fires on a background queue.
    var fired = false
    for _ in 0..<20 {
      if !recorder.isEmpty {
        fired = true
        break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(fired, "ManifestWatcher did not fire after manifest write")

    let changes = recorder.snapshot
    if case .connectionChange(let manifest)? = changes.first {
      #expect(manifest.endpoint == "http://127.0.0.1:8765")
      #expect(manifest.revision == 1)
    } else {
      Issue.record("Expected .connectionChange, got \(String(describing: changes.first))")
    }
  }

}

private final class FireCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func bump() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

/// Thread-safe recorder for ManifestChange events emitted off MainActor by
/// the watcher's dispatch source. Uses `NSLock` (same pattern as
/// `FireCounter` in this file) rather than `Mutex` so the helper works
/// from `@Sendable` closures in the watcher callback.
final class ManifestChangeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var changes: [ManifestChange] = []

  func record(_ change: ManifestChange) {
    lock.lock()
    changes.append(change)
    lock.unlock()
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return changes.count
  }

  var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return changes.isEmpty
  }

  var snapshot: [ManifestChange] {
    lock.lock()
    defer { lock.unlock() }
    return changes
  }
}

/// Shared payload builder for watcher tests. Produces a full
/// `DaemonManifest` JSON payload using snake_case keys so the watcher's
/// `keyDecodingStrategy = .convertFromSnakeCase` decoder accepts it.
enum ManifestWatcherTestPayloads {
  static func daemonManifest(
    endpoint: String,
    startedAt: String,
    revision: UInt64,
    hostBridgeRunning: Bool
  ) -> String {
    let hostBridgeRunningLiteral = hostBridgeRunning ? "true" : "false"
    return """
      {
        "version": "19.5.2",
        "pid": 4242,
        "endpoint": "\(endpoint)",
        "started_at": "\(startedAt)",
        "token_path": "/tmp/token",
        "sandboxed": true,
        "host_bridge": {
          "running": \(hostBridgeRunningLiteral),
          "socket_path": "/tmp/bridge.sock",
          "capabilities": {}
        },
        "revision": \(revision),
        "updated_at": "\(startedAt)"
      }
      """
  }
}

/// Deterministic launch agent manager for guard/state tests. Unlike
/// `RecordingDaemonController` this exercises the real `DaemonController`
/// directly so the ownership gate is actually invoked.
private struct FakeLaunchAgentManager: DaemonLaunchAgentManaging {
  let state: DaemonLaunchAgentRegistrationState

  func registrationState() -> DaemonLaunchAgentRegistrationState { state }
  func register() throws {}
  func unregister() throws {}
}
