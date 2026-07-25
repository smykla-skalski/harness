import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func configureDetailDelay(_ delay: Duration?, for sessionID: String) {
    lock.withLock {
      if let delay {
        detailDelaysBySessionID[sessionID] = delay
      } else {
        detailDelaysBySessionID.removeValue(forKey: sessionID)
      }
    }
  }

  func configureSessionDetailError(_ error: (any Error)?, for sessionID: String) {
    lock.withLock {
      if let error {
        sessionDetailErrorsByID[sessionID] = error
      } else {
        sessionDetailErrorsByID.removeValue(forKey: sessionID)
      }
    }
  }

  func configuredSessionDetailError(for sessionID: String) -> (any Error)? {
    lock.withLock { sessionDetailErrorsByID[sessionID] }
  }

  func configureTimelineError(_ error: (any Error)?, for sessionID: String) {
    lock.withLock {
      if let error {
        timelineErrorsBySessionID[sessionID] = error
      } else {
        timelineErrorsBySessionID.removeValue(forKey: sessionID)
      }
    }
  }

  func configuredTimelineError(for sessionID: String) -> (any Error)? {
    lock.withLock { timelineErrorsBySessionID[sessionID] }
  }

  func configureTimelineDelay(_ delay: Duration?, for sessionID: String) {
    lock.withLock {
      if let delay {
        timelineDelaysBySessionID[sessionID] = delay
      } else {
        timelineDelaysBySessionID.removeValue(forKey: sessionID)
      }
    }
  }

  func configureTimelineWindowResponse(
    _ response: TimelineWindowResponse,
    for sessionID: String
  ) {
    lock.withLock {
      timelineWindowResponsesBySessionID[sessionID] = response
    }
  }

  func configuredTimelineWindowResponse(for sessionID: String) -> TimelineWindowResponse? {
    lock.withLock { timelineWindowResponsesBySessionID[sessionID] }
  }

  func configureTimelineWindowDelay(_ delay: Duration?, for sessionID: String) {
    lock.withLock {
      if let delay {
        timelineWindowDelaysBySessionID[sessionID] = delay
      } else {
        timelineWindowDelaysBySessionID.removeValue(forKey: sessionID)
      }
    }
  }

  func configuredTimelineWindowDelay(for sessionID: String) -> Duration? {
    lock.withLock { timelineWindowDelaysBySessionID[sessionID] }
  }

  func configureTimelineWindowError(_ error: (any Error)?, for sessionID: String) {
    lock.withLock {
      if let error {
        timelineWindowErrorsBySessionID[sessionID] = error
      } else {
        timelineWindowErrorsBySessionID.removeValue(forKey: sessionID)
      }
    }
  }

  func configuredTimelineWindowError(for sessionID: String) -> (any Error)? {
    lock.withLock { timelineWindowErrorsBySessionID[sessionID] }
  }

  func configureCodexRuns(_ runs: [CodexRunSnapshot], for sessionID: String) {
    lock.withLock {
      codexRunsBySessionID[sessionID] = runs
    }
  }

  func configureCodexRunsDelay(_ delay: Duration?, for sessionID: String) {
    lock.withLock {
      if let delay {
        codexRunsDelaysBySessionID[sessionID] = delay
      } else {
        codexRunsDelaysBySessionID.removeValue(forKey: sessionID)
      }
    }
  }

  func configureAgentTuis(_ tuis: [AgentTuiSnapshot], for sessionID: String) {
    lock.withLock {
      agentTuisBySessionID[sessionID] = tuis
    }
  }

  func configureAgentTuisDelay(_ delay: Duration?, for sessionID: String) {
    lock.withLock {
      if let delay {
        agentTuisDelaysBySessionID[sessionID] = delay
      } else {
        agentTuisDelaysBySessionID.removeValue(forKey: sessionID)
      }
    }
  }

  func configureAgentTuiInputResponses(_ snapshots: [AgentTuiSnapshot], for tuiID: String) {
    lock.withLock {
      agentTuiInputResponsesByID[tuiID] = snapshots
    }
  }
  func configureAgentTuiInputError(_ error: (any Error)?, for tuiID: String) {
    lock.withLock {
      if let error {
        agentTuiInputErrorsByID[tuiID] = error
      } else {
        agentTuiInputErrorsByID.removeValue(forKey: tuiID)
      }
    }
  }
  func configureAgentTuiResizeError(_ error: (any Error)?, for tuiID: String) {
    lock.withLock {
      if let error {
        agentTuiResizeErrorsByID[tuiID] = error
      } else {
        agentTuiResizeErrorsByID.removeValue(forKey: tuiID)
      }
    }
  }
  func configureAgentTuiStopError(_ error: (any Error)?, for tuiID: String) {
    lock.withLock {
      if let error {
        agentTuiStopErrorsByID[tuiID] = error
      } else {
        agentTuiStopErrorsByID.removeValue(forKey: tuiID)
      }
    }
  }
  func configureAgentTuiReadError(_ error: (any Error)?, for tuiID: String) {
    lock.withLock {
      if let error {
        agentTuiReadErrorsByID[tuiID] = error
      } else {
        agentTuiReadErrorsByID.removeValue(forKey: tuiID)
      }
    }
  }

  func configureAgentTuiReadSnapshots(_ snapshots: [AgentTuiSnapshot], for tuiID: String) {
    lock.withLock {
      agentTuiReadSnapshotsByID[tuiID] = snapshots
    }
  }
}
