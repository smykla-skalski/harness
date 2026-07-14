@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func configureGlobalStream(
    events: [DaemonPushEvent],
    error: (any Error)? = nil,
    failureCount: Int? = nil
  ) {
    lock.withLock {
      globalStreamEvents = events
      if let failureCount, failureCount <= 0 {
        globalStreamError = nil
        globalStreamErrorRemainingUses = nil
      } else {
        globalStreamError = error
        globalStreamErrorRemainingUses = error == nil ? nil : failureCount
      }
    }
  }

  func configureSessionStream(
    events: [DaemonPushEvent],
    error: (any Error)? = nil,
    for sessionID: String
  ) {
    lock.withLock {
      sessionStreamEventsBySessionID[sessionID] = events
      if let error {
        sessionStreamErrorsBySessionID[sessionID] = error
      } else {
        sessionStreamErrorsBySessionID.removeValue(forKey: sessionID)
      }
    }
  }
}
