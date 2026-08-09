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

    LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { _ in
      LegacyLaunchAgentManagerStub(state: .notRegistered)
    }

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
    defaults.set(
      LegacyManagedLaunchAgentCleanup.strategyVersion,
      forKey: LegacyManagedLaunchAgentCleanup.strategyVersionDefaultsKey
    )

    LegacyManagedLaunchAgentCleanup.resetForTests()
    defer { LegacyManagedLaunchAgentCleanup.resetForTests() }

    LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { _ in
      LegacyLaunchAgentManagerStub(state: .notRegistered)
    }

    let stored =
      defaults.stringArray(
        forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
      ) ?? []
    #expect(stored.sorted() == preExisting)
  }

  @Test("Old cleanup markers are retried under the current strategy")
  func oldCleanupMarkersAreRetried() throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let legacy = HarnessMonitorPaths.legacyLaunchAgentPlistNames
      .filter { $0 != HarnessMonitorPaths.launchAgentPlistName }
    defaults.set(
      legacy,
      forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
    )

    LegacyManagedLaunchAgentCleanup.resetForTests()
    defer { LegacyManagedLaunchAgentCleanup.resetForTests() }
    var attempted: [String] = []
    LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { name in
      attempted.append(name)
      return LegacyLaunchAgentManagerStub(state: .enabled)
    }

    #expect(attempted.sorted() == legacy.sorted())
    #expect(
      defaults.integer(
        forKey: LegacyManagedLaunchAgentCleanup.strategyVersionDefaultsKey
      ) == LegacyManagedLaunchAgentCleanup.strategyVersion
    )
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

    LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { _ in
      LegacyLaunchAgentManagerStub(state: .enabled)
    }

    let stored =
      defaults.stringArray(
        forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
      ) ?? []
    #expect(stored.sorted() == legacy.sorted())
  }

  @Test("Failed unregister retries are bounded and never recorded as complete")
  func failedUnregisterRetriesAreBounded() throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defer { LegacyManagedLaunchAgentCleanup.resetForTests() }

    for expectedAttempt in 1...LegacyManagedLaunchAgentCleanup.maximumAttempts {
      LegacyManagedLaunchAgentCleanup.resetForTests()
      LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { _ in
        LegacyLaunchAgentManagerStub(state: .enabled, unregisterFails: true)
      }
      let counts = try #require(
        defaults.dictionary(
          forKey: LegacyManagedLaunchAgentCleanup.attemptCountsDefaultsKey
        ) as? [String: Int]
      )
      for name in HarnessMonitorPaths.legacyLaunchAgentPlistNames {
        #expect(counts[name] == expectedAttempt)
      }
    }

    LegacyManagedLaunchAgentCleanup.resetForTests()
    var createdManager = false
    LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { _ in
      createdManager = true
      return LegacyLaunchAgentManagerStub(state: .enabled)
    }

    #expect(createdManager == false)
    let completedNames =
      defaults.stringArray(
        forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
      ) ?? []
    #expect(completedNames.isEmpty)
  }
}

private struct LegacyLaunchAgentManagerStub: DaemonLaunchAgentManaging {
  let state: DaemonLaunchAgentRegistrationState
  var unregisterFails = false

  func registrationState() -> DaemonLaunchAgentRegistrationState { state }
  func register() throws {}

  func unregister() throws {
    if unregisterFails {
      throw LegacyLaunchAgentManagerStubError.unregisterFailed
    }
  }
}

private enum LegacyLaunchAgentManagerStubError: Error {
  case unregisterFailed
}
