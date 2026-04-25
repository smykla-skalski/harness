import Foundation

extension DaemonController {
  static func managedStaleManifestSignature(for manifest: DaemonManifest) -> String {
    "\(manifest.pid)|\(manifest.endpoint)|\(manifest.startedAt)"
  }

  static func managedVersionMismatchSignature(for manifest: DaemonManifest) -> String {
    "\(managedStaleManifestSignature(for: manifest))|version=\(manifest.version)"
  }

  static func warmUpObservedManifestMessage(pid: Int, endpoint: String) -> String {
    "Warm-up observed manifest pid=\(pid) endpoint=\(endpoint)"
  }

  static func warmUpStaleManifestMessage(path: String, endpoint: String) -> String {
    "Warm-up found stale daemon manifest at \(path) endpoint=\(endpoint)"
  }

  static func warmUpDeadManagedManifestMessage(pid: Int, path: String) -> String {
    "Warm-up detected dead managed daemon pid \(pid) stale-manifest=\(path)"
  }

  static func warmUpManagedStaleManifestTimeoutMessage(
    path: String,
    gracePeriod: String
  ) -> String {
    "Warm-up aborting managed stale manifest wait at \(path) grace-period=\(gracePeriod)"
  }

  static func warmUpManagedReplacementManifestWaitMessage(path: String) -> String {
    "Warm-up waiting for managed daemon replacement manifest at \(path) after launch-agent refresh"
  }

  static func warmUpManagedReplacementManifestTimeoutMessage(
    path: String,
    gracePeriod: String
  ) -> String {
    "Warm-up aborting managed daemon replacement wait at \(path) grace-period=\(gracePeriod)"
  }

  static func warmUpManagedVersionMismatchWaitMessage(
    path: String,
    expected: String,
    actual: String
  ) -> String {
    """
    Warm-up waiting for managed daemon version mismatch to clear at \(path) \
    expected=\(expected) actual=\(actual)
    """
  }

  static func warmUpManagedVersionMismatchTimeoutMessage(
    path: String,
    expected: String,
    actual: String,
    gracePeriod: String
  ) -> String {
    """
    Warm-up aborting managed daemon version mismatch wait at \(path) \
    expected=\(expected) actual=\(actual) grace-period=\(gracePeriod)
    """
  }

  static func processIsAlive(pid: Int) -> Bool? {
    guard pid > 0 else {
      return nil
    }

    if kill(pid_t(pid), 0) == 0 {
      return true
    }

    switch errno {
    case ESRCH:
      return false
    case EPERM:
      return true
    default:
      return nil
    }
  }

  static func signalProcessToExit(pid: Int) {
    guard pid > 0 else { return }
    if kill(pid_t(pid), SIGTERM) == 0 {
      HarnessMonitorLogger.lifecycle.trace(
        "Sent SIGTERM to stale daemon pid=\(pid, privacy: .public)"
      )
    }
  }
}
