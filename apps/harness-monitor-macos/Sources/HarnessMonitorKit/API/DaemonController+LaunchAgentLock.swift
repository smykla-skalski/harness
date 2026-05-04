import Darwin
import Foundation

// `Darwin.flock` resolves to the `struct flock` used by `fcntl(2)`.
// Bind the BSD `flock(2)` C symbol to a private Swift name so the
// operation-style call below is unambiguous.
@_silgen_name("flock")
private func bsdFlock(_ fd: Int32, _ operation: Int32) -> Int32

extension DaemonController {
  enum LaunchAgentLockOutcome<Value>: Sendable where Value: Sendable {
    case acquired(Value)
    case contended
  }

  /// Try-acquire `flock(LOCK_EX|LOCK_NB)` on a daemon-root sentinel
  /// file, holding it across the supplied closure. The lock
  /// serializes the marker-read / decide / IPC / marker-write
  /// transaction across sibling Monitor processes that resolve to
  /// the same daemon root (e.g. two non-agent profiles with no
  /// `HARNESS_MONITOR_RUNTIME_PROFILE`).
  ///
  /// Lock semantics:
  /// - `flock(2)` is per open-file-description on Darwin, so two
  ///   distinct `open(2)` calls (whether in the same process or
  ///   across processes) yield conflicting locks. POSIX `fcntl`
  ///   locks would not — two threads in the same process would
  ///   silently both "acquire" the lock. Keep `flock(2)`.
  /// - `O_CLOEXEC` prevents a `posix_spawn(2)` of the daemon helper
  ///   (or any future fork) from inheriting the lock-holding fd
  ///   into a subprocess that outlives the refresh transaction.
  /// - On contention we retry every `retryInterval` until
  ///   `totalTimeout`, then return `.contended` so callers can
  ///   defer rather than throw.
  ///
  /// Caveat (tracked as F6 follow-up): the lock currently spans the
  /// `SMAppService.register()` / `unregister()` IPC. If launchd is
  /// wedged on the helper job, the holder hangs the IPC and every
  /// sibling waits out their `totalTimeout` before falling through
  /// to `.contended`. The cost is bounded (250ms per sibling) but
  /// real. Threading an `OwnerSnapshot` through the warm-up entry
  /// (F6) would let us shrink the lock to just marker-read /
  /// decide / marker-write and run the IPC outside.
  func withManagedLaunchAgentLock<Value>(
    totalTimeout: TimeInterval = 0.250,
    retryInterval: TimeInterval = 0.025,
    perform: () throws -> Value
  ) throws -> LaunchAgentLockOutcome<Value> {
    let url = HarnessMonitorPaths.managedLaunchAgentLockURL(using: environment)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    if fd < 0 {
      let err = errno
      throw DaemonControlError.commandFailed(
        "Failed to open managed launch-agent lock at \(url.path): errno=\(err)"
      )
    }
    defer { _ = Darwin.close(fd) }

    let deadline = Date().addingTimeInterval(totalTimeout)
    while true {
      if bsdFlock(fd, LOCK_EX | LOCK_NB) == 0 {
        defer { _ = bsdFlock(fd, LOCK_UN) }
        return .acquired(try perform())
      }
      let err = errno
      if err != EWOULDBLOCK && err != EAGAIN {
        throw DaemonControlError.commandFailed(
          "Failed to acquire managed launch-agent lock at \(url.path): errno=\(err)"
        )
      }
      if Date() >= deadline {
        return .contended
      }
      Thread.sleep(forTimeInterval: retryInterval)
    }
  }
}
