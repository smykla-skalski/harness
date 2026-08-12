import Darwin
import Foundation
import Testing
import os

@testable import HarnessMonitorKit

@_silgen_name("flock")
private func bsdFlock(_ fd: Int32, _ operation: Int32) -> Int32

extension DaemonControllerManagedLaunchAgentWarmUpTests {
  @Test(
    "awaitManifestWarmUp returns early after the managed manifest remains missing for the recovery grace"
  )
  func awaitManifestWarmUpStopsAfterMissingManifestRecoveryGrace() async throws {
    let fixture = TempHarnessMonitorEnvironmentFixture()
    let manager = RecordingLaunchAgentManager(state: .enabled)
    let gracePeriod: Duration = .milliseconds(100)
    let controller = DaemonController(
      environment: fixture.environment,
      launchAgentManager: manager,
      ownership: .managed,
      managedStaleManifestGracePeriod: gracePeriod,
      warmUpBackoff: .init(
        initial: .milliseconds(10),
        multiplier: 1,
        cap: .milliseconds(10)
      )
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    await #expect(throws: DaemonControlError.manifestMissing) {
      _ = try await controller.awaitManifestWarmUp(timeout: .seconds(1))
    }

    let elapsed = startedAt.duration(to: clock.now)
    #expect(elapsed >= gracePeriod)
    #expect(elapsed < .milliseconds(500))
    #expect(manager.unregisterCallCount == 0)
    #expect(manager.registerCallCount == 0)
  }

  @Test(
    "awaitManifestWarmUp returns early after the managed manifest remains unreadable for the recovery grace"
  )
  func awaitManifestWarmUpStopsAfterUnreadableManifestRecoveryGrace() async throws {
    let fixture = TempHarnessMonitorEnvironmentFixture()
    let manifestURL = HarnessMonitorPaths.manifestURL(using: fixture.environment)
    try FileManager.default.createDirectory(
      at: manifestURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: true)
    let manager = RecordingLaunchAgentManager(state: .enabled)
    let gracePeriod: Duration = .milliseconds(100)
    let controller = DaemonController(
      environment: fixture.environment,
      launchAgentManager: manager,
      ownership: .managed,
      managedStaleManifestGracePeriod: gracePeriod,
      warmUpBackoff: .init(
        initial: .milliseconds(10),
        multiplier: 1,
        cap: .milliseconds(10)
      )
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    await #expect(throws: DaemonControlError.manifestUnreadable) {
      _ = try await controller.awaitManifestWarmUp(timeout: .seconds(1))
    }

    let elapsed = startedAt.duration(to: clock.now)
    #expect(elapsed >= gracePeriod)
    #expect(elapsed < .milliseconds(500))
    #expect(manager.unregisterCallCount == 0)
    #expect(manager.registerCallCount == 0)
  }

  @Test(
    "awaitManifestWarmUp retains its full timeout when a daemon holds the singleton lock without a manifest"
  )
  func awaitManifestWarmUpRetainsTimeoutForMissingManifestWhileSingletonLockIsHeld()
    async throws
  {
    let fixture = TempHarnessMonitorEnvironmentFixture()
    let lockURL = HarnessMonitorPaths.daemonSingletonLockURL(using: fixture.environment)
    try FileManager.default.createDirectory(
      at: lockURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    _ = FileManager.default.createFile(atPath: lockURL.path, contents: nil)
    let heldDescriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
    #expect(heldDescriptor >= 0)
    #expect(bsdFlock(heldDescriptor, LOCK_EX | LOCK_NB) == 0)
    defer { _ = Darwin.close(heldDescriptor) }

    let manager = RecordingLaunchAgentManager(state: .enabled)
    let timeout: Duration = .milliseconds(200)
    let controller = DaemonController(
      environment: fixture.environment,
      launchAgentManager: manager,
      ownership: .managed,
      managedStaleManifestGracePeriod: .milliseconds(50),
      warmUpBackoff: .init(
        initial: .milliseconds(10),
        multiplier: 1,
        cap: .milliseconds(10)
      )
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    await #expect(throws: DaemonControlError.manifestMissing) {
      _ = try await controller.awaitManifestWarmUp(timeout: timeout)
    }

    #expect(startedAt.duration(to: clock.now) >= timeout)
    #expect(manager.unregisterCallCount == 0)
    #expect(manager.registerCallCount == 0)
  }

  @Test(
    "awaitManifestWarmUp retains its full timeout after this process registers a helper"
  )
  func awaitManifestWarmUpRetainsTimeoutForMissingManifestOwnedBySelf() async throws {
    let fixture = TempHarnessMonitorEnvironmentFixture()
    let owner = ManagedLaunchAgentOwner(
      pid: getpid(),
      executablePath: "/Applications/Harness Monitor.app/Contents/MacOS/Harness Monitor",
      registeredAt: Date(),
      bootSessionUUID: "current-boot"
    )
    let ownerURL = HarnessMonitorPaths.managedLaunchAgentOwnerURL(using: fixture.environment)
    try FileManager.default.createDirectory(
      at: ownerURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(owner).write(to: ownerURL, options: .atomic)

    let manager = RecordingLaunchAgentManager(state: .enabled)
    let timeout: Duration = .milliseconds(200)
    let controller = DaemonController(
      environment: fixture.environment,
      launchAgentManager: manager,
      ownership: .managed,
      managedStaleManifestGracePeriod: .milliseconds(50),
      warmUpBackoff: .init(
        initial: .milliseconds(10),
        multiplier: 1,
        cap: .milliseconds(10)
      )
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    await #expect(throws: DaemonControlError.manifestMissing) {
      _ = try await controller.awaitManifestWarmUp(timeout: timeout)
    }

    #expect(startedAt.duration(to: clock.now) >= timeout)
    #expect(manager.unregisterCallCount == 0)
    #expect(manager.registerCallCount == 0)
  }

  @Test(
    "awaitManifestWarmUp retains its full timeout when a live sibling owns a lane with no manifest"
  )
  func awaitManifestWarmUpRetainsTimeoutForMissingManifestOwnedByLiveSibling() async throws {
    let fixture = TempHarnessMonitorEnvironmentFixture()
    let owner = ManagedLaunchAgentOwner(
      pid: 9001,
      executablePath: "/Applications/Harness Monitor.app/Contents/MacOS/Harness Monitor",
      registeredAt: Date(),
      bootSessionUUID: "current-boot"
    )
    let ownerURL = HarnessMonitorPaths.managedLaunchAgentOwnerURL(using: fixture.environment)
    try FileManager.default.createDirectory(
      at: ownerURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(owner).write(to: ownerURL, options: .atomic)

    let manager = RecordingLaunchAgentManager(state: .enabled)
    let timeout: Duration = .milliseconds(200)
    let controller = DaemonController(
      environment: fixture.environment,
      launchAgentManager: manager,
      ownership: .managed,
      managedStaleManifestGracePeriod: .milliseconds(50),
      warmUpBackoff: .init(
        initial: .milliseconds(10),
        multiplier: 1,
        cap: .milliseconds(10)
      ),
      processLiveness: { pid in
        #expect(pid == owner.pid)
        return .alive(executablePath: owner.executablePath)
      },
      bootSessionUUID: { "current-boot" }
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    await #expect(throws: DaemonControlError.manifestMissing) {
      _ = try await controller.awaitManifestWarmUp(timeout: timeout)
    }

    #expect(startedAt.duration(to: clock.now) >= timeout)
    #expect(manager.unregisterCallCount == 0)
    #expect(manager.registerCallCount == 0)
  }

  @Test(
    "awaitManifestWarmUp starts unavailable grace when a sibling exits before publishing a manifest"
  )
  func awaitManifestWarmUpRecoversWhenLiveSiblingOwnershipBecomesStale() async throws {
    let fixture = TempHarnessMonitorEnvironmentFixture()
    let owner = ManagedLaunchAgentOwner(
      pid: 9002,
      executablePath: "/Applications/Harness Monitor.app/Contents/MacOS/Harness Monitor",
      registeredAt: Date(),
      bootSessionUUID: "current-boot"
    )
    let ownerURL = HarnessMonitorPaths.managedLaunchAgentOwnerURL(using: fixture.environment)
    try FileManager.default.createDirectory(
      at: ownerURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(owner).write(to: ownerURL, options: .atomic)

    let liveness = ManagedOwnerLivenessTransitionProbe(
      executablePath: owner.executablePath
    )
    let manager = RecordingLaunchAgentManager(state: .enabled)
    let gracePeriod: Duration = .milliseconds(100)
    let controller = DaemonController(
      environment: fixture.environment,
      launchAgentManager: manager,
      ownership: .managed,
      managedStaleManifestGracePeriod: gracePeriod,
      warmUpBackoff: .init(
        initial: .milliseconds(10),
        multiplier: 1,
        cap: .milliseconds(10)
      ),
      processLiveness: { pid in
        #expect(pid == owner.pid)
        return liveness.next()
      },
      bootSessionUUID: { "current-boot" }
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    await #expect(throws: DaemonControlError.manifestMissing) {
      _ = try await controller.awaitManifestWarmUp(timeout: .seconds(1))
    }

    let elapsed = startedAt.duration(to: clock.now)
    #expect(elapsed >= gracePeriod)
    #expect(elapsed < .milliseconds(500))
    #expect(!FileManager.default.fileExists(atPath: ownerURL.path))
    #expect(manager.unregisterCallCount == 0)
    #expect(manager.registerCallCount == 0)
  }
}

private final class ManagedOwnerLivenessTransitionProbe: @unchecked Sendable {
  private let executablePath: String
  private let callCount = OSAllocatedUnfairLock(initialState: 0)

  init(executablePath: String) {
    self.executablePath = executablePath
  }

  func next() -> ProcessLiveness {
    let count = callCount.withLock { count in
      count += 1
      return count
    }
    return count <= 2 ? .alive(executablePath: executablePath) : .dead
  }
}
