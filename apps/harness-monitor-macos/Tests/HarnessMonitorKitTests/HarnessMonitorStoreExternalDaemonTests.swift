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
}
