import Darwin
import Foundation
import Testing

@testable import HarnessMonitorKit

// `Darwin.flock` resolves to `struct flock` (used by `fcntl(2)`).
// Bind the BSD `flock(2)` C symbol to a private name so test
// helpers can hold the lock unambiguously.
@_silgen_name("flock")
private func bsdFlock(_ fd: Int32, _ operation: Int32) -> Int32

private let managedLaunchAgentHelperPathFixture =
  "/Users/example/Library/Developer/Xcode/DerivedData/HarnessMonitor/Build/Products/Debug/"
  + "Harness Monitor.app/Contents/Helpers/harness-daemon"

extension DaemonControllerManagedLaunchAgentWarmUpTests {
  /// The stale manifest names the previous daemon's pid, which is already dead
  /// while its replacement is still booting. Warm-up used to read that as "no
  /// daemon" and refresh the launch agent, killing the daemon mid-boot.
  @Test(
    "awaitManifestWarmUp leaves the launch agent alone while a daemon holds the singleton lock"
  )
  func awaitManifestWarmUpWaitsWhileSingletonLockIsHeld() async throws {
    try await withTempDaemonFixture(pid: 999_999) { environment in
      let client = PreviewHarnessClient()
      try writeManagedLaunchAgentBundleStampFixture(
        ManagedLaunchAgentBundleStampFixture(
          helperPath: "/Applications/Harness Monitor.app/Contents/Helpers/harness-daemon",
          deviceIdentifier: 41,
          inode: 84,
          fileSize: 16_384,
          modificationTimeIntervalSince1970: 1_713_000_000
        ),
        environment: environment
      )

      // Stand in for the booting daemon: hold the singleton lock without ever
      // publishing a manifest.
      let lockURL = HarnessMonitorPaths.daemonSingletonLockURL(using: environment)
      try FileManager.default.createDirectory(
        at: lockURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      FileManager.default.createFile(atPath: lockURL.path, contents: nil)
      let heldDescriptor = Darwin.open(lockURL.path, O_RDWR | O_CLOEXEC)
      #expect(heldDescriptor >= 0)
      #expect(bsdFlock(heldDescriptor, LOCK_EX | LOCK_NB) == 0)
      defer { _ = Darwin.close(heldDescriptor) }

      let manager = HookedLaunchAgentManager(state: .enabled)
      let controller = DaemonController(
        environment: environment,
        transportPreference: .http,
        launchAgentManager: manager,
        ownership: .managed,
        sessionFactory: { _ in client },
        endpointProbe: { _ in false },
        managedLaunchAgentCurrentBundleStamp: {
          ManagedLaunchAgentBundleStamp(
            helperPath: managedLaunchAgentHelperPathFixture,
            deviceIdentifier: 99,
            inode: 128,
            fileSize: 32_768,
            modificationTimeIntervalSince1970: 1_714_000_000
          )
        }
      )

      await #expect(throws: (any Error).self) {
        _ = try await controller.awaitManifestWarmUp(timeout: .milliseconds(400))
      }

      #expect(
        manager.unregisterCallCount == 0,
        "a daemon holding the singleton lock must not be torn down mid-boot"
      )
      #expect(manager.registerCallCount == 0)
    }
  }
}
