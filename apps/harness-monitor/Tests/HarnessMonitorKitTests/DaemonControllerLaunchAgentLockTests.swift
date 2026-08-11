import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

// `Darwin.flock` resolves to `struct flock` (used by `fcntl(2)`).
// Bind the BSD `flock(2)` C symbol to a private name so test
// helpers can hold/release the lock unambiguously.
@_silgen_name("flock")
func testBSDFileLock(_ fd: Int32, _ operation: Int32) -> Int32

@Suite("DaemonController managed launch-agent lock")
struct DaemonControllerLaunchAgentLockTests {
  @Test("Acquired path runs the closure and returns its value")
  func acquiredPathRunsClosureAndReturnsValue() async throws {
    try await withTempDaemonFixture(pid: 1) { environment in
      let controller = DaemonController(environment: environment, ownership: .managed)
      let outcome = try await controller.withManagedLaunchAgentLock {
        42
      }
      switch outcome {
      case .acquired(let value):
        #expect(value == 42)
      case .contended:
        Issue.record("Expected .acquired, got .contended")
      }
    }
  }

  @Test("Closure errors propagate through the wrapper")
  func closureErrorsPropagateThroughTheWrapper() async throws {
    struct Boom: Error, Equatable {}
    try await withTempDaemonFixture(pid: 1) { environment in
      let controller = DaemonController(environment: environment, ownership: .managed)
      do {
        _ = try await controller.withManagedLaunchAgentLock { () async throws -> Int in
          throw Boom()
        }
        Issue.record("Expected throw, got return")
      } catch is Boom {
        // expected
      } catch {
        Issue.record("Wrong error type: \(error)")
      }
    }
  }

  @Test("External flock holder forces .contended within bounded timeout")
  func externalFlockHolderForcesContendedWithinBoundedTimeout() async throws {
    try await withTempDaemonFixture(pid: 1) { environment in
      let lockURL = HarnessMonitorPaths.managedLaunchAgentLockURL(using: environment)
      try FileManager.default.createDirectory(
        at: lockURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let externalFD = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
      #expect(externalFD >= 0)
      defer { _ = Darwin.close(externalFD) }
      #expect(testBSDFileLock(externalFD, LOCK_EX | LOCK_NB) == 0)
      defer { _ = testBSDFileLock(externalFD, LOCK_UN) }

      let controller = DaemonController(environment: environment, ownership: .managed)
      let started = Date()
      let outcome = try await controller.withManagedLaunchAgentLock(
        totalTimeout: .milliseconds(100),
        retryInterval: .milliseconds(20)
      ) {
        Issue.record("Closure should not run while external flock is held")
        return 0
      }
      let elapsed = Date().timeIntervalSince(started)
      switch outcome {
      case .contended:
        #expect(elapsed >= 0.090, "Should have retried until ~totalTimeout, got \(elapsed)s")
        #expect(elapsed < 0.500, "Should not block far past totalTimeout, got \(elapsed)s")
      case .acquired:
        Issue.record("Expected .contended, got .acquired")
      }
    }
  }

  @Test("Cancellation stops a contended lock acquisition")
  func cancellationStopsContendedLockAcquisition() async throws {
    try await withTempDaemonFixture(pid: 1) { environment in
      let lockURL = HarnessMonitorPaths.managedLaunchAgentLockURL(using: environment)
      try FileManager.default.createDirectory(
        at: lockURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let externalFD = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
      #expect(externalFD >= 0)
      defer { _ = Darwin.close(externalFD) }
      #expect(testBSDFileLock(externalFD, LOCK_EX | LOCK_NB) == 0)
      defer { _ = testBSDFileLock(externalFD, LOCK_UN) }

      let controller = DaemonController(environment: environment, ownership: .managed)
      let waiter = Task {
        try await controller.withManagedLaunchAgentLock(
          totalTimeout: .seconds(5),
          retryInterval: .milliseconds(20)
        ) {
          Issue.record("Cancelled lock closure must not run")
          return 0
        }
      }
      try await Task.sleep(for: .milliseconds(50))
      waiter.cancel()

      await #expect(throws: CancellationError.self) {
        _ = try await waiter.value
      }
    }
  }

  @Test("Lock releases after the closure so subsequent acquires succeed")
  func lockReleasesAfterClosureSoSubsequentAcquiresSucceed() async throws {
    try await withTempDaemonFixture(pid: 1) { environment in
      let controller = DaemonController(environment: environment, ownership: .managed)
      _ = try await controller.withManagedLaunchAgentLock { () }

      let lockURL = HarnessMonitorPaths.managedLaunchAgentLockURL(using: environment)
      let fd = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
      #expect(fd >= 0)
      defer { _ = Darwin.close(fd) }
      let lockResult = testBSDFileLock(fd, LOCK_EX | LOCK_NB)
      #expect(lockResult == 0, "Lock should be free after wrapper closure exits")
      _ = testBSDFileLock(fd, LOCK_UN)
    }
  }

  @Test("Launch refresh revalidates the helper stamp after acquiring the lock")
  func launchRefreshRevalidatesStampUnderLock() async throws {
    try await withTempDaemonFixture(pid: 1) { environment in
      let lockURL = HarnessMonitorPaths.managedLaunchAgentLockURL(using: environment)
      try FileManager.default.createDirectory(
        at: lockURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      let externalFD = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
      #expect(externalFD >= 0)
      defer { _ = Darwin.close(externalFD) }
      #expect(testBSDFileLock(externalFD, LOCK_EX | LOCK_NB) == 0)

      let stamp = ManagedLaunchAgentBundleStamp(
        helperPath: "/Applications/Harness Monitor.app/Contents/Helpers/harness-daemon",
        deviceIdentifier: 1,
        inode: 2,
        fileSize: 3,
        modificationTimeIntervalSince1970: 4
      )
      let stampReads = ManagedLaunchAgentStampReadCounter(stamp: stamp)
      let manager = RecordingLaunchAgentManager(state: .enabled)
      let controller = DaemonController(
        environment: environment,
        launchAgentManager: manager,
        ownership: .managed,
        managedLaunchAgentCurrentBundleStamp: { stampReads.read() }
      )
      let refresh = Task {
        try await controller.refreshManagedLaunchAgentForLaunch()
      }

      for _ in 0..<100 where stampReads.count < 1 {
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(stampReads.count >= 1)
      try controller.persistManagedLaunchAgentBundleStamp(
        stamp,
        to: HarnessMonitorPaths.managedLaunchAgentBundleStampURL(using: environment)
      )
      #expect(testBSDFileLock(externalFD, LOCK_UN) == 0)

      #expect(try await refresh.value == false)
      #expect(stampReads.count >= 2)
      #expect(manager.unregisterCallCount == 0)
      #expect(manager.registerCallCount == 0)
    }
  }

  @Test("Service coordination URLs follow the lane-specific service identity")
  func serviceCoordinationURLsFollowServiceIdentity() {
    let homeDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let laneA = HarnessMonitorEnvironment(
      values: [HarnessMonitorRuntimeLane.environmentKey: "lane-a"],
      homeDirectory: homeDirectory
    )
    let laneB = HarnessMonitorEnvironment(
      values: [
        HarnessMonitorRuntimeLane.environmentKey: "lane-b",
        HarnessMonitorAppGroup.daemonDataHomeEnvironmentKey:
          homeDirectory
          .appendingPathComponent("custom-data", isDirectory: true).path,
      ],
      homeDirectory: homeDirectory
    )

    #expect(
      HarnessMonitorPaths.managedLaunchAgentLockURL(using: laneA)
        != HarnessMonitorPaths.managedLaunchAgentLockURL(using: laneB)
    )
    #expect(
      HarnessMonitorPaths.managedLaunchAgentOwnerURL(using: laneA)
        != HarnessMonitorPaths.managedLaunchAgentOwnerURL(using: laneB)
    )
    #expect(
      HarnessMonitorPaths.managedLaunchAgentBundleStampURL(using: laneA)
        != HarnessMonitorPaths.managedLaunchAgentBundleStampURL(using: laneB)
    )
    #expect(
      HarnessMonitorPaths.legacyManagedLaunchAgentLockURL(using: laneA)
        == HarnessMonitorPaths.legacyManagedLaunchAgentLockURL(using: laneB)
    )
  }
}

private final class ManagedLaunchAgentStampReadCounter: @unchecked Sendable {
  private let lock = NSLock()
  private let stamp: ManagedLaunchAgentBundleStamp
  private var protectedCount = 0

  init(stamp: ManagedLaunchAgentBundleStamp) {
    self.stamp = stamp
  }

  var count: Int {
    lock.withLock { protectedCount }
  }

  func read() -> ManagedLaunchAgentBundleStamp {
    lock.withLock {
      protectedCount += 1
      return stamp
    }
  }
}
