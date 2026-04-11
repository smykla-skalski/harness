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
    #expect(store.lastError == nil)
  }

  @Test("External bootstrap reports external offline error with manifest path")
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
    #expect(message.contains("harness daemon dev"))
    #expect(message.contains(manifestPath))
  }

  @Test("Managed bootstrap still gates on launch agent registration state")
  func managedBootstrapGatesOnRegistrationState() async {
    let daemon = RecordingDaemonController(
      launchAgentInstalled: false,
      registrationState: .notRegistered
    )
    let store = HarnessMonitorStore(daemonController: daemon)

    await store.bootstrap()

    guard case .offline(let message) = store.connectionState else {
      Issue.record("Expected offline connection state, got \(store.connectionState)")
      return
    }
    #expect(message.contains("Launch agent"))
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
    // Non-DaemonControlError falls back to the generic guidance message.
    #expect(message.contains("harness daemon dev"))
  }

  @Test("Ownership init reads HARNESS_MONITOR_EXTERNAL_DAEMON")
  func ownershipInitReadsEnvironmentFlag() {
    #if DEBUG
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
      DaemonOwnership(environment: [DaemonOwnership.environmentKey: "0"])
        == .managed
    )
    #expect(
      DaemonOwnership(environment: [DaemonOwnership.environmentKey: "false"])
        == .managed
    )
    #else
    // Release builds ignore the flag entirely.
    #expect(
      DaemonOwnership(environment: [DaemonOwnership.environmentKey: "1"])
        == .managed
    )
    #endif
  }

  @Test("External daemon offline error mentions the harness daemon dev command")
  func externalDaemonOfflineErrorMessageMentionsDevCommand() {
    let error = DaemonControlError.externalDaemonOffline(manifestPath: "/tmp/x")
    let description = error.errorDescription ?? ""
    #expect(description.contains("harness daemon dev"))
    #expect(description.contains("/tmp/x"))
  }

  @Test("Stale manifest error message is distinct and mentions the path")
  func staleManifestErrorHasDistinctWording() {
    let error = DaemonControlError.externalDaemonManifestStale(
      manifestPath: "/tmp/y/manifest.json"
    )
    let description = error.errorDescription ?? ""
    #expect(description.contains("Stale manifest"))
    #expect(description.contains("/tmp/y/manifest.json"))
    #expect(description.contains("harness daemon dev"))
  }

  @Test("External bootstrap surfaces stale manifest error when warm-up throws it")
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
    #expect(message.contains("Stale manifest"))
    #expect(message.contains("/tmp/stale/manifest.json"))
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
