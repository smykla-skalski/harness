import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

// `Darwin.flock` resolves to `struct flock` (used by `fcntl(2)`).
// Bind the BSD `flock(2)` C symbol to a private name so test
// helpers can hold/release the lock unambiguously.
@_silgen_name("flock")
private func bsdFlock(_ fd: Int32, _ operation: Int32) -> Int32

@Suite("DaemonController managed launch-agent lock")
struct DaemonControllerLaunchAgentLockTests {
  @Test("Acquired path runs the closure and returns its value")
  func acquiredPathRunsClosureAndReturnsValue() async throws {
    try await withTempDaemonFixture(pid: 1) { environment in
      let controller = DaemonController(environment: environment, ownership: .managed)
      let outcome = try controller.withManagedLaunchAgentLock {
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
        _ = try controller.withManagedLaunchAgentLock { () throws -> Int in
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
      #expect(bsdFlock(externalFD, LOCK_EX | LOCK_NB) == 0)
      defer { _ = bsdFlock(externalFD, LOCK_UN) }

      let controller = DaemonController(environment: environment, ownership: .managed)
      let started = Date()
      let outcome = try controller.withManagedLaunchAgentLock(
        totalTimeout: 0.100,
        retryInterval: 0.020
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

  @Test("Lock releases after the closure so subsequent acquires succeed")
  func lockReleasesAfterClosureSoSubsequentAcquiresSucceed() async throws {
    try await withTempDaemonFixture(pid: 1) { environment in
      let controller = DaemonController(environment: environment, ownership: .managed)
      _ = try controller.withManagedLaunchAgentLock { () }

      let lockURL = HarnessMonitorPaths.managedLaunchAgentLockURL(using: environment)
      let fd = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
      #expect(fd >= 0)
      defer { _ = Darwin.close(fd) }
      let lockResult = bsdFlock(fd, LOCK_EX | LOCK_NB)
      #expect(lockResult == 0, "Lock should be free after wrapper closure exits")
      _ = bsdFlock(fd, LOCK_UN)
    }
  }

  @Test("Lock URL lives under the daemon root next to the manifest")
  func lockURLLivesUnderDaemonRootNextToManifest() async throws {
    try await withTempDaemonFixture(pid: 1) { environment in
      let lockURL = HarnessMonitorPaths.managedLaunchAgentLockURL(using: environment)
      let manifestURL = HarnessMonitorPaths.manifestURL(using: environment)
      #expect(lockURL.deletingLastPathComponent() == manifestURL.deletingLastPathComponent())
      #expect(lockURL.lastPathComponent == "managed-launch-agent.lock")
    }
  }
}
