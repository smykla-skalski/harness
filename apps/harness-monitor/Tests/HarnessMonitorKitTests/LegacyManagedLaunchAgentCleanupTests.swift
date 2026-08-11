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

  @Test("Recorded names are rechecked when an older app registers them again")
  func recordedNamesAreRecheckedAfterLegacyReregistration() throws {
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
    defaults.set(
      LegacyManagedLaunchAgentCleanup.strategyVersion,
      forKey: LegacyManagedLaunchAgentCleanup.strategyVersionDefaultsKey
    )
    var unregistered: [String] = []

    let completed = LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { name in
      LegacyLaunchAgentManagerStub(state: .enabled) {
        unregistered.append(name)
      }
    }

    #expect(completed)
    #expect(unregistered.sorted() == legacy.sorted())
  }

  @Test("Cleanup excludes the controller lane service")
  func cleanupExcludesControllerLaneService() throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let currentName = "Q498EB36N4.io.harnessmonitor.managed-service-lane-a.plist"
    let legacyName = "Q498EB36N4.io.harnessmonitor.agent-lane-a.plist"
    var inspectedNames: [String] = []

    let completed = LegacyManagedLaunchAgentCleanup.runOnce(
      defaults: defaults,
      currentName: currentName,
      legacyNames: [legacyName, currentName]
    ) { name in
      inspectedNames.append(name)
      return LegacyLaunchAgentManagerStub(state: .notRegistered)
    }

    #expect(completed)
    #expect(inspectedNames == [legacyName])
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

    LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { _ in
      LegacyLaunchAgentManagerStub(state: .enabled)
    }

    let stored =
      defaults.stringArray(
        forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
      ) ?? []
    #expect(stored.sorted() == legacy.sorted())
  }

  @Test("Failed unregister disables the current service and remains retryable")
  func failedUnregisterDisablesCurrentServiceAndRemainsRetryable() throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var currentServiceUnregisterCount = 0
    let firstResult = LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { name in
      if name == HarnessMonitorPaths.launchAgentPlistName {
        return LegacyLaunchAgentManagerStub(
          state: .enabled,
          unregisterFails: true
        ) {
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

    var sameProcessRetryCount = 0
    let retryResult = LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { _ in
      sameProcessRetryCount += 1
      return LegacyLaunchAgentManagerStub(state: .notRegistered)
    }
    #expect(retryResult)
    #expect(sameProcessRetryCount > 0)

    var calledAfterSuccess = false
    let recheckedSuccess = LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { _ in
      calledAfterSuccess = true
      return LegacyLaunchAgentManagerStub(state: .enabled)
    }
    #expect(recheckedSuccess)
    #expect(calledAfterSuccess)
    let completedAfterRetry =
      defaults.stringArray(
        forKey: LegacyManagedLaunchAgentCleanup.completedNamesDefaultsKey
      ) ?? []
    let expected = HarnessMonitorPaths.legacyLaunchAgentPlistNames
      .filter { $0 != HarnessMonitorPaths.launchAgentPlistName }
    #expect(completedAfterRetry.sorted() == expected.sorted())
  }

  @Test("Current service unregister settles before the cleanup retry")
  func currentServiceUnregisterSettlesBeforeRetry() async throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let recorder = LegacyCleanupAttemptRecorder(currentUnregisterFails: false)

    try await LegacyManagedLaunchAgentCleanup.requireComplete(
      defaults: defaults,
      managerFactory: { recorder.manager(for: $0) },
      afterCurrentServiceUnregister: {
        recorder.record("settled")
      },
      quiesceOnFailure: {
        recorder.record("quiesced")
      }
    )

    let events = recorder.events()
    let currentUnregister = try #require(events.firstIndex(of: "current-unregister"))
    let settled = try #require(events.firstIndex(of: "settled"))
    let retry = try #require(events.firstIndex(of: "legacy-retry"))
    #expect(currentUnregister < settled)
    #expect(settled < retry)
    #expect(events.contains("quiesced") == false)
    #expect(recorder.managerFactoryUsedMainThread() == false)
  }

  @Test("Current service failure quiesces once and returns a bounded error")
  func currentServiceFailureQuiescesOnceAndReturnsBoundedError() async throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let recorder = LegacyCleanupAttemptRecorder(currentUnregisterFails: true)

    await #expect(throws: DaemonControlError.self) {
      try await LegacyManagedLaunchAgentCleanup.requireComplete(
        defaults: defaults,
        managerFactory: { recorder.manager(for: $0) },
        afterCurrentServiceUnregister: {
          recorder.record("settled")
        },
        quiesceOnFailure: {
          recorder.record("quiesced")
        }
      )
    }

    #expect(recorder.events().contains("settled") == false)
    #expect(recorder.events().filter { $0 == "quiesced" }.count == 1)

    try await LegacyManagedLaunchAgentCleanup.requireComplete(
      defaults: defaults,
      managerFactory: { recorder.manager(for: $0) },
      afterCurrentServiceUnregister: {
        recorder.record("settled")
      },
      quiesceOnFailure: {
        recorder.record("quiesced-again")
      }
    )

    #expect(recorder.events().contains("quiesced-again") == false)
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

private final class LegacyCleanupAttemptRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private let currentUnregisterFails: Bool
  private var recordedEvents: [String] = []
  private var legacyCalls: [String: Int] = [:]
  private var usedMainThread = false

  init(currentUnregisterFails: Bool) {
    self.currentUnregisterFails = currentUnregisterFails
  }

  func manager(for name: String) -> any DaemonLaunchAgentManaging {
    lock.lock()
    usedMainThread = usedMainThread || Thread.isMainThread
    defer { lock.unlock() }
    if name == HarnessMonitorPaths.launchAgentPlistName {
      return LegacyLaunchAgentManagerStub(
        state: .enabled,
        unregisterFails: currentUnregisterFails,
        onUnregister: { self.record("current-unregister") }
      )
    }

    let callCount = legacyCalls[name, default: 0]
    legacyCalls[name] = callCount + 1
    if callCount == 0 {
      return LegacyLaunchAgentManagerStub(state: .enabled, unregisterFails: true)
    }
    recordedEvents.append("legacy-retry")
    return LegacyLaunchAgentManagerStub(state: .notRegistered)
  }

  func record(_ event: String) {
    lock.lock()
    recordedEvents.append(event)
    lock.unlock()
  }

  func events() -> [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedEvents
  }

  func managerFactoryUsedMainThread() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return usedMainThread
  }
}
