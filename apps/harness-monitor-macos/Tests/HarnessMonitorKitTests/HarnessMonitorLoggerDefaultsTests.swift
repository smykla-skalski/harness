import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Harness Monitor logger defaults")
struct HarnessMonitorLoggerDefaultsTests {
  @Test("Stored supervisor log level defaults to info")
  func storedSupervisorLogLevelDefaultsToInfo() throws {
    let defaults = try isolatedUserDefaults()

    #expect(
      HarnessMonitorLoggerDefaults.storedSupervisorLogLevel(defaults: defaults)
        == HarnessMonitorLogger.defaultSupervisorLogLevel
    )
  }

  @Test("Stored supervisor log level normalizes aliases and invalid values")
  func storedSupervisorLogLevelNormalizesAliasesAndInvalidValues() throws {
    let defaults = try isolatedUserDefaults()

    defaults.set(
      "warning",
      forKey: HarnessMonitorLoggerDefaults.supervisorLogLevelKey
    )
    #expect(
      HarnessMonitorLoggerDefaults.storedSupervisorLogLevel(defaults: defaults)
        == "warn"
    )

    defaults.set(
      "loud",
      forKey: HarnessMonitorLoggerDefaults.supervisorLogLevelKey
    )
    #expect(
      HarnessMonitorLoggerDefaults.storedSupervisorLogLevel(defaults: defaults)
        == HarnessMonitorLogger.defaultSupervisorLogLevel
    )
  }
}

private func isolatedUserDefaults() throws -> UserDefaults {
  let suiteName = "HarnessMonitorLoggerDefaultsTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  return defaults
}
