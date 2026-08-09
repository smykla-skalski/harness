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

  @Test("Failed unregister disables the current service and remains retryable")
  func failedUnregisterDisablesCurrentServiceAndRemainsRetryable() throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defer { LegacyManagedLaunchAgentCleanup.resetForTests() }

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
    let cachedSuccess = LegacyManagedLaunchAgentCleanup.runOnce(defaults: defaults) { _ in
      calledAfterSuccess = true
      return LegacyLaunchAgentManagerStub(state: .enabled)
    }
    #expect(cachedSuccess)
    #expect(calledAfterSuccess == false)
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
    defer { LegacyManagedLaunchAgentCleanup.resetForTests() }
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

  @Test("Persistent current service failure engages the kill switch")
  func persistentCurrentServiceFailureEngagesKillSwitch() async throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defer { LegacyManagedLaunchAgentCleanup.resetForTests() }
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
  }

  @Test("Controller engages the kill switch through the trusted local manifest")
  func controllerEngagesKillSwitchThroughTrustedManifest() async throws {
    let client = RecordingHarnessClient()
    try await withTempDaemonFixture(pid: 1_234) { environment in
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: RecordingLaunchAgentManager(state: .enabled),
        ownership: .managed,
        sessionFactory: { _ in client }
      )

      try await controller.engageAutomationKillSwitchAfterLegacyCleanupFailure()
    }

    let requests = client.lock.withLock {
      client.policyCanvasSpawnKillSwitchRequests
    }
    #expect(requests == [true])
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
