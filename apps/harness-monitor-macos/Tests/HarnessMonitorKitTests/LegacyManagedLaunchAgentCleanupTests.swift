import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Legacy managed launch agent cleanup")
struct LegacyManagedLaunchAgentCleanupTests {
  @Test("First run records every attempted legacy plist name")
  func firstRunRecordsCompletedNames() throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    LegacyManagedLaunchAgentCleanup.resetForTests()
    defer { LegacyManagedLaunchAgentCleanup.resetForTests() }

    LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults)

    let stored =
      defaults.stringArray(
        forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
      ) ?? []
    let expected = HarnessMonitorPaths.legacyLaunchAgentPlistNames
      .filter { $0 != HarnessMonitorPaths.launchAgentPlistName }
      .sorted()
    #expect(stored.sorted() == expected)
  }

  @Test("Subsequent launch with names already recorded writes nothing new")
  func subsequentLaunchSkipsRecordedNames() throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preExisting = HarnessMonitorPaths.legacyLaunchAgentPlistNames
      .filter { $0 != HarnessMonitorPaths.launchAgentPlistName }
      .sorted()
    defaults.set(
      preExisting,
      forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
    )

    LegacyManagedLaunchAgentCleanup.resetForTests()
    defer { LegacyManagedLaunchAgentCleanup.resetForTests() }

    LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults)

    let stored =
      defaults.stringArray(
        forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
      ) ?? []
    #expect(stored.sorted() == preExisting)
  }

  @Test("Pending names are unioned with previously completed ones")
  func pendingNamesUnionWithPreviouslyCompleted() throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let legacy = HarnessMonitorPaths.legacyLaunchAgentPlistNames
      .filter { $0 != HarnessMonitorPaths.launchAgentPlistName }
    let firstOnly = Array(legacy.prefix(1))
    defaults.set(
      firstOnly,
      forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
    )

    LegacyManagedLaunchAgentCleanup.resetForTests()
    defer { LegacyManagedLaunchAgentCleanup.resetForTests() }

    LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults)

    let stored =
      defaults.stringArray(
        forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
      ) ?? []
    #expect(stored.sorted() == legacy.sorted())
  }
}
