import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Legacy managed launch agent cleanup cancellation", .serialized)
struct LegacyManagedLaunchAgentCleanupCancellationTests {
  @Test("Already-clean warm-up skips a second legacy scan")
  func alreadyCleanWarmUpSkipsSecondLegacyScan() async throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-warm-up.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let counter = LegacyCleanupFactoryCounter()
    let environment = HarnessMonitorEnvironment(
      values: [HarnessMonitorAppGroup.environmentKey: suiteName],
      homeDirectory: FileManager.default.temporaryDirectory
    )
    let controller = DaemonController(
      environment: environment,
      launchAgentManager: RecordingLaunchAgentManager(state: .notRegistered),
      legacyLaunchAgentManagerFactory: { _ in counter.manager() },
      legacyLaunchAgentCleanupDefaults: defaults,
      legacyMonitorProcessIsRunning: { false }
    )

    _ = try? await controller.awaitManifestWarmUpAfterLegacyCleanup(timeout: Duration.zero)
    #expect(counter.isEmpty)

    _ = try? await controller.awaitManifestWarmUp(timeout: Duration.zero)
    let currentName = HarnessMonitorPaths.launchAgentPlistName(using: environment)
    let expectedLegacyScanCount = HarnessMonitorPaths.legacyLaunchAgentPlistNames.count {
      $0 != currentName
    }
    #expect(counter.count == expectedLegacyScanCount)
  }

  @Test("Cancellation after a detached attempt prevents startup")
  @MainActor
  func cancellationAfterDetachedAttemptPreventsStartup() async throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let sendableDefaults = SendableUserDefaults(defaults)
    let blocker = BlockingLegacyCleanupFactory()
    let cleanup = Task {
      try await LegacyManagedLaunchAgentCleanup.requireComplete(
        defaults: sendableDefaults.value,
        managerFactory: { blocker.manager(for: $0) },
        afterCurrentServiceUnregister: {},
        quiesceOnFailure: {}
      )
    }

    #expect(await blocker.waitUntilStarted())
    cleanup.cancel()
    blocker.release()

    await #expect(throws: CancellationError.self) {
      try await cleanup.value
    }
  }

  @Test("A running legacy Monitor keeps the current service disabled")
  func runningLegacyMonitorBlocksCleanup() async throws {
    let suiteName =
      "io.harnessmonitor.kit-tests.legacy-cleanup.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let recorder = LegacyMonitorBlockRecorder()

    await #expect(throws: DaemonControlError.self) {
      try await LegacyManagedLaunchAgentCleanup.requireComplete(
        defaults: defaults,
        managerFactory: { recorder.manager(for: $0) },
        legacyMonitorProcessIsRunning: { true },
        afterCurrentServiceUnregister: {
          recorder.recordSettle()
        },
        quiesceOnFailure: {
          recorder.recordQuiesce()
        }
      )
    }

    #expect(recorder.currentUnregisterCount() == 2)
    #expect(recorder.settleCount() == 2)
    #expect(recorder.quiesceCount() == 1)
  }
}

private final class LegacyCleanupFactoryCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var protectedCount = 0

  var count: Int {
    lock.withLock { protectedCount }
  }

  var isEmpty: Bool {
    lock.withLock { protectedCount <= 0 }
  }

  func manager() -> any DaemonLaunchAgentManaging {
    lock.withLock { protectedCount += 1 }
    return RecordingLaunchAgentManager(state: .notRegistered)
  }
}

private final class BlockingLegacyCleanupFactory: @unchecked Sendable {
  private let lock = NSLock()
  private let started = LegacyCleanupAsyncSignal()
  private let proceed = DispatchSemaphore(value: 0)
  private var didBlock = false

  func manager(for name: String) -> any DaemonLaunchAgentManaging {
    let shouldBlock = lock.withLock { () -> Bool in
      guard !didBlock else { return false }
      didBlock = true
      return true
    }
    if shouldBlock {
      started.signal()
      proceed.wait()
    }
    return LegacyCancellationLaunchAgentManager(state: .notRegistered)
  }

  func waitUntilStarted() async -> Bool {
    await started.wait()
    return true
  }

  func release() {
    proceed.signal()
  }
}

private final class LegacyCleanupAsyncSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var isSignalled = false
  private var continuation: CheckedContinuation<Void, Never>?

  func signal() {
    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
      isSignalled = true
      let current = self.continuation
      self.continuation = nil
      return current
    }
    continuation?.resume()
  }

  func wait() async {
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock { () -> Bool in
        if isSignalled {
          return true
        }
        self.continuation = continuation
        return false
      }
      if shouldResume {
        continuation.resume()
      }
    }
  }
}

private final class LegacyMonitorBlockRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var unregisters = 0
  private var settles = 0
  private var quiesces = 0

  func manager(for name: String) -> any DaemonLaunchAgentManaging {
    guard name == HarnessMonitorPaths.launchAgentPlistName else {
      return LegacyCancellationLaunchAgentManager(state: .notRegistered)
    }
    return LegacyCancellationLaunchAgentManager(state: .enabled) {
      self.lock.withLock { self.unregisters += 1 }
    }
  }

  func recordSettle() {
    lock.withLock { settles += 1 }
  }

  func recordQuiesce() {
    lock.withLock { quiesces += 1 }
  }

  func currentUnregisterCount() -> Int {
    lock.withLock { unregisters }
  }

  func settleCount() -> Int {
    lock.withLock { settles }
  }

  func quiesceCount() -> Int {
    lock.withLock { quiesces }
  }
}

private final class LegacyCancellationLaunchAgentManager:
  DaemonLaunchAgentManaging, @unchecked Sendable
{
  let state: DaemonLaunchAgentRegistrationState
  let onUnregister: () -> Void

  init(
    state: DaemonLaunchAgentRegistrationState,
    onUnregister: @escaping () -> Void = {}
  ) {
    self.state = state
    self.onUnregister = onUnregister
  }

  func registrationState() -> DaemonLaunchAgentRegistrationState { state }
  func register() throws {}
  func unregister() throws { onUnregister() }
}
