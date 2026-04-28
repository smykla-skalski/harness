import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func recordedCalls() -> [Call] {
    calls
  }

  func configureHealthDelay(_ delay: Duration?) {
    lock.withLock {
      healthDelay = delay
    }
  }

  func configureTransportLatencyMs(_ latencyMs: Int?) {
    lock.withLock {
      transportLatencyMsValue = latencyMs
    }
  }

  func configureTransportLatencyError(_ error: (any Error)?) {
    lock.withLock {
      transportLatencyError = error
    }
  }

  func configureDiagnosticsDelay(_ delay: Duration?) {
    lock.withLock {
      diagnosticsDelay = delay
    }
  }

  func configureDiagnosticsErrors(_ errors: [any Error]) {
    lock.withLock {
      queuedDiagnosticsErrors = errors
    }
  }

  func configureProjectsDelay(_ delay: Duration?) {
    lock.withLock {
      projectsDelay = delay
    }
  }

  func configureProjectsErrors(_ errors: [any Error]) {
    lock.withLock {
      queuedProjectsErrors = errors
    }
  }

  func configureSessionsDelay(_ delay: Duration?) {
    lock.withLock {
      sessionsDelay = delay
    }
  }

  func configureSessionsErrors(_ errors: [any Error]) {
    lock.withLock {
      queuedSessionsErrors = errors
    }
  }

  func configureMutationDelay(_ delay: Duration?) {
    lock.withLock {
      mutationDelay = delay
    }
  }

  func configureSessions(
    summaries: [SessionSummary],
    detailsByID: [String: SessionDetail],
    timelinesBySessionID: [String: [TimelineEntry]] = [:]
  ) {
    lock.withLock {
      var projectsByID: [String: ProjectFixture] = [:]
      var orderedProjectIDs: [String] = []

      for summary in summaries {
        if projectsByID[summary.projectId] == nil {
          orderedProjectIDs.append(summary.projectId)
          projectsByID[summary.projectId] = ProjectFixture(
            name: summary.projectName,
            projectDir: summary.projectDir,
            contextRoot: summary.contextRoot,
            activeSessionCount: 0,
            totalSessionCount: 0
          )
        }

        guard var project = projectsByID[summary.projectId] else {
          continue
        }
        project.totalSessionCount += 1
        if summary.status != .ended {
          project.activeSessionCount += 1
        }
        projectsByID[summary.projectId] = project
      }

      projectSummariesStorage = orderedProjectIDs.compactMap { projectID in
        guard let project = projectsByID[projectID] else {
          return nil
        }

        return ProjectSummary(
          projectId: projectID,
          name: project.name,
          projectDir: project.projectDir,
          contextRoot: project.contextRoot,
          activeSessionCount: project.activeSessionCount,
          totalSessionCount: project.totalSessionCount
        )
      }
      sessionSummariesStorage = summaries
      sessionDetailsByID = detailsByID
      self.timelinesBySessionID = timelinesBySessionID
    }
  }

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

  func configureGlobalStream(
    events: [DaemonPushEvent],
    error: (any Error)? = nil
  ) {
    lock.withLock {
      globalStreamEvents = events
      globalStreamError = error
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

  func configureCodexStartError(_ error: (any Error)?) {
    lock.withLock {
      codexStartError = error
      queuedCodexStartErrors = []
    }
  }

  func configureCodexStartErrors(_ errors: [any Error]) {
    lock.withLock {
      queuedCodexStartErrors = errors
      codexStartError = nil
    }
  }

  func configureAgentTuiStartError(_ error: (any Error)?) {
    lock.withLock { agentTuiStartError = error }
  }

  func configureHostBridgeReconfigureError(_ error: (any Error)?) {
    lock.withLock { hostBridgeReconfigureError = error }
  }

  func configureHostBridgeStatusReport(_ report: BridgeStatusReport) {
    lock.withLock { hostBridgeStatusReport = report }
  }

  func configuredCodexStartError() -> (any Error)? {
    lock.withLock { codexStartError }
  }

  func dequeueConfiguredCodexStartError() -> (any Error)? {
    lock.withLock {
      guard let error = queuedCodexStartErrors.first else {
        return codexStartError
      }
      queuedCodexStartErrors.removeFirst()
      return error
    }
  }

  func configuredAgentTuiStartError() -> (any Error)? {
    lock.withLock { agentTuiStartError }
  }

  func configuredHostBridgeReconfigureError() -> (any Error)? {
    lock.withLock { hostBridgeReconfigureError }
  }

  func configuredHostBridgeStatusReport() -> BridgeStatusReport {
    lock.withLock { hostBridgeStatusReport }
  }

  func configuredHealthDelay() -> Duration? { lock.withLock { healthDelay } }
  func configuredTransportLatencyMs() -> Int? { lock.withLock { transportLatencyMsValue } }
  func configuredTransportLatencyError() -> (any Error)? {
    lock.withLock { transportLatencyError }
  }
  func configuredDiagnosticsDelay() -> Duration? { lock.withLock { diagnosticsDelay } }
  func configuredProjectsDelay() -> Duration? { lock.withLock { projectsDelay } }
  func configuredSessionsDelay() -> Duration? { lock.withLock { sessionsDelay } }

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
