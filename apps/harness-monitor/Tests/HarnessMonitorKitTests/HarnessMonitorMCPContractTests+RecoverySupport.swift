import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorMCPContractTests {
  func isolatedRecoveryDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "io.harnessmonitor.tests.mcp.recovery.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defaults.register(defaults: HarnessMonitorMCPSettingsDefaults.registrationDefaults())
    return (defaults, suiteName)
  }

  /// A yield count is not a bound on progress. Under a loaded run the work
  /// being waited for can stay unscheduled through every one of them, so the
  /// wait gives up early and the test reports a failure the code never had.
  /// Bound the wait in time instead, and sleep between checks so the executor
  /// is free to run that work rather than the spin.
  func waitForCondition(
    timeout: Duration = .seconds(10),
    poll: Duration = .milliseconds(10),
    condition: @escaping @MainActor () -> Bool
  ) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if condition() {
        return
      }
      do {
        try await Task.sleep(for: poll)
      } catch {
        // Cancellation makes every later sleep throw at once, so swallowing it
        // would turn this back into the spin it replaced.
        break
      }
    }
    #expect(condition())
  }
}

@MainActor
final class RecoveryStubMCPService: HarnessMonitorMCPStartupControlling {
  private let fallbackEnabledRuntimeState: HarnessMonitorMCPRuntimeState
  var runtimeState: HarnessMonitorMCPRuntimeState = .disabled
  var nextEnabledRuntimeStates: [HarnessMonitorMCPRuntimeState]
  var nextProbeRuntimeStates: [HarnessMonitorMCPRuntimeState] = []
  private(set) var recordedEnabledStates: [Bool] = []

  init(
    nextEnabledRuntimeStates: [HarnessMonitorMCPRuntimeState],
    fallbackEnabledRuntimeState: HarnessMonitorMCPRuntimeState = .healthy(
      socketPath: "/tmp/mcp.sock"
    )
  ) {
    self.nextEnabledRuntimeStates = nextEnabledRuntimeStates
    self.fallbackEnabledRuntimeState = fallbackEnabledRuntimeState
  }

  func setEnabled(_ enabled: Bool) async {
    recordedEnabledStates.append(enabled)
    guard enabled else {
      runtimeState = .disabled
      return
    }

    if nextEnabledRuntimeStates.isEmpty {
      runtimeState = fallbackEnabledRuntimeState
    } else {
      runtimeState = nextEnabledRuntimeStates.removeFirst()
    }
  }

  func probeRuntimeState() async -> HarnessMonitorMCPRuntimeState {
    if nextProbeRuntimeStates.isEmpty {
      return runtimeState
    }
    runtimeState = nextProbeRuntimeStates.removeFirst()
    return runtimeState
  }
}
