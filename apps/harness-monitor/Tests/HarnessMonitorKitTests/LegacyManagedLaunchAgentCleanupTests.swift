import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Legacy managed launch agent cleanup", .serialized)
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

  @Test("Failed unregister disables the current service and retries next launch")
  func failedUnregisterDisablesCurrentServiceAndRetries() throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defer { LegacyManagedLaunchAgentCleanup.resetForTests() }

    var currentServiceUnregisterCount = 0
    let firstResult = LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { name in
      if name == HarnessMonitorPaths.launchAgentPlistName {
        return LegacyLaunchAgentManagerStub(state: .enabled) {
          currentServiceUnregisterCount += 1
        }
      }
      return LegacyLaunchAgentManagerStub(state: .enabled, unregisterFails: true)
    }

    #expect(firstResult == false)
    #expect(currentServiceUnregisterCount == 1)
    let completedAfterFailure =
      defaults.stringArray(
        forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
      ) ?? []
    #expect(completedAfterFailure.isEmpty)

    var retriedInSameProcess = false
    let cachedResult = LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { _ in
      retriedInSameProcess = true
      return LegacyLaunchAgentManagerStub(state: .notRegistered)
    }
    #expect(cachedResult == false)
    #expect(retriedInSameProcess == false)

    LegacyManagedLaunchAgentCleanup.resetForTests()
    let retryResult = LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { _ in
      LegacyLaunchAgentManagerStub(state: .notRegistered)
    }

    #expect(retryResult)
    let completedAfterRetry =
      defaults.stringArray(
        forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
      ) ?? []
    let expected = HarnessMonitorPaths.legacyLaunchAgentPlistNames
      .filter { $0 != HarnessMonitorPaths.launchAgentPlistName }
    #expect(completedAfterRetry.sorted() == expected.sorted())
  }
}

private final class LegacyLaunchAgentManagerStub: DaemonLaunchAgentManaging, @unchecked Sendable {
  let state: DaemonLaunchAgentRegistrationState
  let unregisterFails: Bool
  let onUnregister: () -> Void

  init(
    state: DaemonLaunchAgentRegistrationState,
    unregisterFails: Bool = false,
    onUnregister: @escaping () -> Void = {}
  ) {
    self.state = state
    self.unregisterFails = unregisterFails
    self.onUnregister = onUnregister
  }

  func registrationState() -> DaemonLaunchAgentRegistrationState { state }
  func register() throws {}

  func unregister() throws {
    onUnregister()
    if unregisterFails {
      throw LegacyLaunchAgentManagerStubError.unregisterFailed
    }
  }
}

private enum LegacyLaunchAgentManagerStubError: Error {
  case unregisterFailed
}
