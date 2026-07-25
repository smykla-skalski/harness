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
  /// the same daemon root (e.g. two processes with no
  /// `HARNESS_MONITOR_RUNTIME_LANE`).
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
  /// Caveat: the lock currently spans the `SMAppService.register()` /
  /// `unregister()` IPC plus the short post-unregister BTM settle
  /// wait. If launchd is wedged on the helper job, the holder hangs
  /// and every sibling waits out their `totalTimeout` before falling
  /// through to `.contended`.
  func withManagedLaunchAgentLock<Value>(
    totalTimeout: Duration = .milliseconds(250),
    retryInterval: Duration = .milliseconds(25),
    perform: () async throws -> Value
  ) async throws -> LaunchAgentLockOutcome<Value> where Value: Sendable {
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

    let deadline = ContinuousClock.now + totalTimeout
    while true {
      if bsdFlock(fd, LOCK_EX | LOCK_NB) == 0 {
        defer { _ = bsdFlock(fd, LOCK_UN) }
        return .acquired(try await perform())
      }
      let err = errno
      if err != EWOULDBLOCK && err != EAGAIN {
        throw DaemonControlError.commandFailed(
          "Failed to acquire managed launch-agent lock at \(url.path): errno=\(err)"
        )
      }
      if ContinuousClock.now >= deadline {
        return .contended
      }
      try? await Task.sleep(for: retryInterval)
    }
  }
}

extension DaemonController {
  /// True while some process holds the daemon singleton lock.
  ///
  /// A stale manifest names the pid of the daemon that wrote it, and that
  /// process is already gone by the time the manifest looks stale. Its death
  /// says nothing about whether a replacement is on its way up, so treating it
  /// as "no daemon" tore down a daemon that was mid-boot. The singleton lock is
  /// taken before the daemon binds a port or writes anything, so it answers the
  /// question the dead pid cannot.
  ///
  /// Mirrors the daemon's own probe: never creates the file, and holds the
  /// exclusive lock only long enough to learn it was free. Taking it briefly
  /// can lose a race with a daemon acquiring it at the same instant, which is
  /// the same tradeoff the daemon-side probe already accepts.
  func daemonSingletonLockIsHeld() -> Bool {
    let url = HarnessMonitorPaths.daemonSingletonLockURL(using: environment)
    let fd = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
    guard fd >= 0 else {
      return false
    }
    defer { _ = Darwin.close(fd) }

    if bsdFlock(fd, LOCK_EX | LOCK_NB) == 0 {
      _ = bsdFlock(fd, LOCK_UN)
      return false
    }
    return errno == EWOULDBLOCK
  }
}
