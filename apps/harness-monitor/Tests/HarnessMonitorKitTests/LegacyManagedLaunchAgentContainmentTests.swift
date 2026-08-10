import AppKit
import Foundation
import Testing

@testable import HarnessMonitorKit

@Suite("Legacy managed launch-agent containment", .serialized)
struct LegacyManagedLaunchAgentContainmentTests {
  @Test("Clean containment has no polling work")
  @MainActor
  func cleanContainmentDoesNotPoll() async throws {
    let daemon = RecordingDaemonController()
    let callbacks = LegacyContainmentCallbackRecorder()
    let containment = LegacyManagedLaunchAgentContainment(
      initialRetryDelay: .milliseconds(10),
      maximumRetryDelay: .milliseconds(20)
    )

    containment.start(
      controller: daemon,
      failureActive: false,
      onFailure: { _, _ in await callbacks.recordFailure() },
      onRecovery: { _, token in
        if containment.claimRecovery(requestGeneration: token) {
          await callbacks.recordRecovery()
        }
      }
    )
    try await Task.sleep(for: .milliseconds(50))
    #expect(await daemon.recordedLegacyCleanupCallCount() == 0)

    containment.requestCheck()
    await waitForLegacyCleanupCalls(daemon, count: 1)
    try await Task.sleep(for: .milliseconds(30))
    containment.cancel()

    #expect(await daemon.recordedLegacyCleanupCallCount() == 1)
    #expect(await callbacks.snapshot() == .init(failures: 0, recoveries: 0))
  }

  @Test("Containment retries failures and reports recovery")
  @MainActor
  func containmentRetriesAndRecovers() async throws {
    let daemon = RecordingDaemonController(
      legacyCleanupError: DaemonControlError.commandFailed("legacy service returned")
    )
    let callbacks = LegacyContainmentCallbackRecorder()
    let containment = LegacyManagedLaunchAgentContainment(
      initialRetryDelay: .milliseconds(10),
      maximumRetryDelay: .milliseconds(20)
    )

    containment.start(
      controller: daemon,
      failureActive: true,
      onFailure: { _, _ in await callbacks.recordFailure() },
      onRecovery: { _, token in
        if containment.claimRecovery(requestGeneration: token) {
          await callbacks.recordRecovery()
        }
      }
    )
    await waitForLegacyCleanupCalls(daemon, count: 1)
    await daemon.setLegacyCleanupError(nil)

    for _ in 0..<20 where await callbacks.snapshot().recoveries == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    containment.cancel()

    #expect(await daemon.recordedLegacyCleanupCallCount() >= 2)
    #expect(await callbacks.snapshot() == .init(failures: 0, recoveries: 1))
  }

  @Test("Lifecycle request interrupts active retry backoff")
  @MainActor
  func lifecycleRequestInterruptsActiveRetryBackoff() async throws {
    let daemon = RecordingDaemonController(
      legacyCleanupError: DaemonControlError.commandFailed("legacy service returned")
    )
    let callbacks = LegacyContainmentCallbackRecorder()
    let containment = LegacyManagedLaunchAgentContainment(
      initialRetryDelay: .seconds(5),
      maximumRetryDelay: .seconds(5)
    )

    containment.start(
      controller: daemon,
      failureActive: true,
      onFailure: { _, _ in await callbacks.recordFailure() },
      onRecovery: { _, token in
        if containment.claimRecovery(requestGeneration: token) {
          await callbacks.recordRecovery()
        }
      }
    )
    await waitForLegacyCleanupCalls(daemon, count: 1)
    await daemon.setLegacyCleanupError(nil)
    let started = ContinuousClock.now

    containment.requestCheck()
    for _ in 0..<20 where await callbacks.snapshot().recoveries == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    containment.cancel()

    #expect(started.duration(to: .now) < .milliseconds(250))
    #expect(await callbacks.snapshot().recoveries == 1)
  }

  @Test("Lifecycle request during cleanup survives a failed attempt")
  @MainActor
  func lifecycleRequestDuringCleanupSurvivesFailure() async throws {
    let gate = LegacyContainmentCleanupGate()
    let daemon = RecordingDaemonController(
      legacyCleanupHandler: {
        guard await gate.waitIfFirstAttempt() else { return }
        throw DaemonControlError.commandFailed("legacy service returned")
      }
    )
    let callbacks = LegacyContainmentCallbackRecorder()
    let containment = LegacyManagedLaunchAgentContainment(
      initialRetryDelay: .seconds(5),
      maximumRetryDelay: .seconds(5)
    )

    containment.start(
      controller: daemon,
      failureActive: true,
      onFailure: { _, _ in await callbacks.recordFailure() },
      onRecovery: { _, token in
        if containment.claimRecovery(requestGeneration: token) {
          await callbacks.recordRecovery()
        }
      }
    )
    for _ in 0..<20 where await gate.hasWaiter == false {
      try await Task.sleep(for: .milliseconds(10))
    }
    let started = ContinuousClock.now
    containment.requestCheck()
    await gate.release()
    for _ in 0..<20 where await callbacks.snapshot().recoveries == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    containment.cancel()

    #expect(started.duration(to: .now) < .milliseconds(250))
    #expect(await callbacks.snapshot().recoveries == 1)
  }

  @Test("Queued lifecycle check runs before recovery")
  @MainActor
  func queuedLifecycleCheckRunsBeforeRecovery() async throws {
    let gate = LegacyContainmentSuccessThenFailureGate()
    let daemon = RecordingDaemonController(
      legacyCleanupHandler: { try await gate.run() }
    )
    let callbacks = LegacyContainmentCallbackRecorder()
    let containment = LegacyManagedLaunchAgentContainment(
      initialRetryDelay: .seconds(5),
      maximumRetryDelay: .seconds(5)
    )

    containment.start(
      controller: daemon,
      failureActive: true,
      onFailure: { _, _ in await callbacks.recordFailure() },
      onRecovery: { _, token in
        if containment.claimRecovery(requestGeneration: token) {
          await callbacks.recordRecovery()
        }
      }
    )
    for _ in 0..<20 where await gate.hasWaiter == false {
      try await Task.sleep(for: .milliseconds(10))
    }
    containment.requestCheck()
    await gate.release()
    await waitForLegacyCleanupCalls(daemon, count: 2)
    try await Task.sleep(for: .milliseconds(30))
    containment.cancel()

    #expect(await callbacks.snapshot().recoveries == 0)
  }

  @Test("Unrelated app lifecycle does not request containment")
  func unrelatedAppLifecycleDoesNotRequestContainment() {
    #expect(
      LegacyManagedLaunchAgentContainment.shouldCheckApplicationLifecycle(
        bundleIdentifier: "com.apple.TextEdit"
      ) == false
    )
    #expect(
      LegacyManagedLaunchAgentContainment.shouldCheckApplicationLifecycle(
        bundleIdentifier: "io.harnessmonitor.app"
      )
    )
  }

  @Test("Only process lifecycle changes invalidate the legacy Monitor scan")
  func processScanInvalidationFollowsProcessLifecycle() {
    #expect(
      LegacyManagedLaunchAgentContainment.invalidatesLegacyMonitorProcessScan(
        for: NSWorkspace.didLaunchApplicationNotification
      )
    )
    #expect(
      LegacyManagedLaunchAgentContainment.invalidatesLegacyMonitorProcessScan(
        for: NSWorkspace.didTerminateApplicationNotification
      )
    )
    #expect(
      LegacyManagedLaunchAgentContainment.invalidatesLegacyMonitorProcessScan(
        for: NSWorkspace.didWakeNotification
      ) == false
    )
    #expect(
      LegacyManagedLaunchAgentContainment.invalidatesLegacyMonitorProcessScan(
        for: NSApplication.didBecomeActiveNotification
      ) == false
    )
  }

  @Test("New request invalidates an earlier recovery token")
  @MainActor
  func newRequestInvalidatesEarlierRecoveryToken() async throws {
    let daemon = RecordingDaemonController()
    let tokenRecorder = LegacyContainmentRecoveryTokenRecorder()
    let containment = LegacyManagedLaunchAgentContainment()

    containment.start(
      controller: daemon,
      failureActive: true,
      onFailure: { _, _ in },
      onRecovery: { _, token in await tokenRecorder.record(token) }
    )
    for _ in 0..<20 where await tokenRecorder.firstToken == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    let token = try #require(await tokenRecorder.firstToken)

    containment.requestCheck()
    #expect(containment.claimRecovery(requestGeneration: token) == false)
    containment.cancel()
  }

  @Test("New request transfers pending recovery to its successful check")
  @MainActor
  func newRequestTransfersPendingRecovery() async throws {
    let daemon = RecordingDaemonController()
    let gate = LegacyContainmentRecoveryCallbackGate()
    let callbacks = LegacyContainmentCallbackRecorder()
    let containment = LegacyManagedLaunchAgentContainment()

    containment.start(
      controller: daemon,
      failureActive: true,
      onFailure: { _, _ in },
      onRecovery: { _, token in
        await gate.waitIfFirstCallback()
        if containment.claimRecovery(requestGeneration: token) {
          await callbacks.recordRecovery()
        }
      }
    )
    for _ in 0..<20 where await gate.firstCallbackEntered == false {
      try await Task.sleep(for: .milliseconds(10))
    }

    containment.requestCheck()
    await waitForLegacyCleanupCalls(daemon, count: 2)
    for _ in 0..<20 where await callbacks.snapshot().recoveries == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    await gate.releaseFirstCallback()
    try await Task.sleep(for: .milliseconds(20))
    containment.cancel()

    #expect(await callbacks.snapshot().recoveries == 1)
  }

  @Test("Cancellation suppresses a late cleanup failure callback")
  @MainActor
  func cancellationSuppressesLateFailureCallback() async throws {
    let gate = LegacyContainmentVoidGate()
    let daemon = RecordingDaemonController(
      legacyCleanupHandler: {
        await gate.wait()
        throw DaemonControlError.commandFailed("legacy service returned")
      }
    )
    let callbacks = LegacyContainmentCallbackRecorder()
    let containment = LegacyManagedLaunchAgentContainment()

    containment.start(
      controller: daemon,
      failureActive: false,
      onFailure: { _, taskID in
        if containment.claimFailure(taskID: taskID) {
          await callbacks.recordFailure()
        }
      },
      onRecovery: { _, _ in }
    )
    containment.requestCheck()
    for _ in 0..<30 where await gate.hasEntered == false {
      try await Task.sleep(for: .milliseconds(20))
    }
    containment.cancel()
    await gate.release()
    try await Task.sleep(for: .milliseconds(30))

    #expect(await callbacks.snapshot().failures == 0)
  }

  private func waitForLegacyCleanupCalls(
    _ daemon: RecordingDaemonController,
    count: Int
  ) async {
    for _ in 0..<20 where await daemon.recordedLegacyCleanupCallCount() < count {
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}

private actor LegacyContainmentRecoveryTokenRecorder {
  private(set) var firstToken: UInt64?

  func record(_ token: UInt64) {
    if firstToken == nil {
      firstToken = token
    }
  }
}

private actor LegacyContainmentRecoveryCallbackGate {
  private var callCount = 0
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var firstCallbackEntered = false

  func waitIfFirstCallback() async {
    callCount += 1
    guard callCount == 1 else { return }
    firstCallbackEntered = true
    await withCheckedContinuation { continuation = $0 }
  }

  func releaseFirstCallback() {
    continuation?.resume()
    continuation = nil
  }
}

private actor LegacyContainmentSuccessThenFailureGate {
  private var attempt = 0
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var hasWaiter = false

  func run() async throws {
    attempt += 1
    if attempt == 1 {
      hasWaiter = true
      await withCheckedContinuation { continuation = $0 }
      return
    }
    throw DaemonControlError.commandFailed("legacy service returned")
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private actor LegacyContainmentCleanupGate {
  private var didBlock = false
  private var continuation: CheckedContinuation<Void, Never>?
  private(set) var hasWaiter = false

  func waitIfFirstAttempt() async -> Bool {
    guard !didBlock else { return false }
    didBlock = true
    hasWaiter = true
    await withCheckedContinuation { continuation = $0 }
    return true
  }

  func release() {
    continuation?.resume()
    continuation = nil
  }
}

private struct LegacyContainmentCallbackSnapshot: Equatable {
  let failures: Int
  let recoveries: Int
}

private actor LegacyContainmentCallbackRecorder {
  private var failures = 0
  private var recoveries = 0

  func recordFailure() {
    failures += 1
  }

  func recordRecovery() {
    recoveries += 1
  }

  func snapshot() -> LegacyContainmentCallbackSnapshot {
    LegacyContainmentCallbackSnapshot(failures: failures, recoveries: recoveries)
  }
}
