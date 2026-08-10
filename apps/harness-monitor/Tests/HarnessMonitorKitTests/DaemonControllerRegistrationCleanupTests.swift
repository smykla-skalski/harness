import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Daemon controller registration cleanup")
struct DaemonControllerRegistrationCleanupTests {
  @Test("registerLaunchAgent disables current service when post-register cleanup fails")
  func registerLaunchAgentDisablesCurrentServiceWhenCleanupFails() async throws {
    let environmentFixture = TempHarnessMonitorEnvironmentFixture()
    let manager = RecordingLaunchAgentManager(state: .notRegistered)
    let unregisterError = DaemonControlError.commandFailed("legacy unregister failed")
    let legacyManager = HookedLaunchAgentManager(
      state: .enabled,
      onUnregister: { throw unregisterError }
    )
    let currentName = HarnessMonitorPaths.launchAgentPlistName(
      using: environmentFixture.environment
    )
    let defaultsSuite = "register-cleanup-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let controller = DaemonController(
      environment: environmentFixture.environment,
      launchAgentManager: manager,
      legacyLaunchAgentManagerFactory: { name in
        if name == currentName {
          manager
        } else {
          legacyManager
        }
      },
      legacyLaunchAgentCleanupDefaults: defaults,
      legacyMonitorProcessIsRunning: { false },
      managedLaunchAgentBTMSettleDelay: .zero
    )

    await #expect(throws: DaemonControlError.self) {
      _ = try await controller.registerLaunchAgent()
    }

    #expect(manager.registerCallCount == 1)
    #expect(manager.unregisterCallCount == 1)
    #expect(manager.state == .notRegistered)
    #expect(legacyManager.registrationState() == .enabled)
  }

  @Test("Cancelled post-register cleanup disables current service")
  func cancelledPostRegisterCleanupDisablesCurrentService() async throws {
    let environmentFixture = TempHarnessMonitorEnvironmentFixture()
    let manager = RecordingLaunchAgentManager(state: .notRegistered)
    let processScanGate = LegacyContainmentVoidGate()
    let currentName = HarnessMonitorPaths.launchAgentPlistName(
      using: environmentFixture.environment
    )
    let defaultsSuite = "register-cancel-cleanup-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
    defer { defaults.removePersistentDomain(forName: defaultsSuite) }
    let controller = DaemonController(
      environment: environmentFixture.environment,
      launchAgentManager: manager,
      legacyLaunchAgentManagerFactory: { name in
        name == currentName ? manager : RecordingLaunchAgentManager(state: .notRegistered)
      },
      legacyLaunchAgentCleanupDefaults: defaults,
      legacyMonitorProcessIsRunning: {
        await processScanGate.wait()
        return false
      },
      managedLaunchAgentBTMSettleDelay: .zero
    )
    let registration = Task { try await controller.registerLaunchAgent() }

    for _ in 0..<30 where await processScanGate.hasEntered == false {
      try await Task.sleep(for: .milliseconds(20))
    }
    registration.cancel()
    await processScanGate.release()

    await #expect(throws: CancellationError.self) {
      _ = try await registration.value
    }
    #expect(manager.registerCallCount == 1)
    #expect(manager.unregisterCallCount == 1)
    #expect(manager.state == .notRegistered)
  }
}
