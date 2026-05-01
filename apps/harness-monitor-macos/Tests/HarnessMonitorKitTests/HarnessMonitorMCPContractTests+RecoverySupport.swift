import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension HarnessMonitorMCPContractTests {
  func isolatedRecoveryDefaults() throws -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "io.harnessmonitor.tests.mcp.recovery.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    defaults.register(defaults: HarnessMonitorMCPPreferencesDefaults.registrationDefaults())
    return (defaults, suiteName)
  }

  func waitForCondition(
    attempts: Int = 40,
    condition: @escaping @MainActor () -> Bool
  ) async {
    for _ in 0..<attempts {
      if condition() {
        return
      }
      await Task.yield()
    }
    #expect(condition())
  }
}

@MainActor
final class RecoveryStubMCPService: HarnessMonitorMCPStartupControlling {
  private let fallbackEnabledRuntimeState: HarnessMonitorMCPRuntimeState
  var runtimeState: HarnessMonitorMCPRuntimeState = .disabled
  var nextEnabledRuntimeStates: [HarnessMonitorMCPRuntimeState]
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
}
