@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func dequeueDiagnosticsError() -> (any Error)? {
    lock.withLock {
      guard !queuedDiagnosticsErrors.isEmpty else {
        return nil
      }
      return queuedDiagnosticsErrors.removeFirst()
    }
  }

  func dequeueProjectsError() -> (any Error)? {
    lock.withLock {
      guard !queuedProjectsErrors.isEmpty else {
        return nil
      }
      return queuedProjectsErrors.removeFirst()
    }
  }

  func dequeueSessionsError() -> (any Error)? {
    lock.withLock {
      guard !queuedSessionsErrors.isEmpty else {
        return nil
      }
      return queuedSessionsErrors.removeFirst()
    }
  }
}
