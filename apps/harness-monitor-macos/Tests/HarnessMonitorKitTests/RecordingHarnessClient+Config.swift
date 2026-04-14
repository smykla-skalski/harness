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

  func configureProjectsDelay(_ delay: Duration?) {
    lock.withLock {
      projectsDelay = delay
    }
  }

  func configureSessionsDelay(_ delay: Duration?) {
    lock.withLock {
      sessionsDelay = delay
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
  func configuredMutationDelay() -> Duration? { lock.withLock { mutationDelay } }
  func configuredProjects() -> [ProjectSummary]? { lock.withLock { projectSummariesStorage } }
  func configuredSessions() -> [SessionSummary]? { lock.withLock { sessionSummariesStorage } }
  func configuredSessionDetail(id: String) -> SessionDetail? {
    lock.withLock { sessionDetailsByID[id] }
  }
  func configuredDetailDelay(for sessionID: String) -> Duration? {
    lock.withLock { detailDelaysBySessionID[sessionID] }
  }
  func sessionDetailScopes(for sessionID: String) -> [String?] {
    lock.withLock { sessionDetailScopesByID[sessionID] ?? [] }
  }
  func configuredTimeline(for sessionID: String) -> [TimelineEntry]? {
    lock.withLock { timelinesBySessionID[sessionID] }
  }
  func timelineScopes(for sessionID: String) -> [TimelineScope] {
    lock.withLock { timelineScopesBySessionID[sessionID] ?? [] }
  }
  func configuredTimelineBatches(for sessionID: String) -> [[TimelineEntry]]? {
    lock.withLock { timelineBatchesBySessionID[sessionID] }
  }
  func configuredTimelineDelay(for sessionID: String) -> Duration? {
    lock.withLock { timelineDelaysBySessionID[sessionID] }
  }
  func configuredTimelineBatchDelay(for sessionID: String) -> Duration? {
    lock.withLock { timelineBatchDelaysBySessionID[sessionID] }
  }
  func configuredCodexRuns(for sessionID: String) -> [CodexRunSnapshot] {
    lock.withLock { codexRunsBySessionID[sessionID] ?? [] }
  }
  func configuredCodexRunsDelay(for sessionID: String) -> Duration? {
    lock.withLock { codexRunsDelaysBySessionID[sessionID] }
  }
  func configuredAgentTuis(for sessionID: String) -> [AgentTuiSnapshot] {
    lock.withLock { agentTuisBySessionID[sessionID] ?? [] }
  }
  func configuredAgentTuisDelay(for sessionID: String) -> Duration? {
    lock.withLock { agentTuisDelaysBySessionID[sessionID] }
  }
  func configuredCodexRun(id runID: String) -> CodexRunSnapshot? {
    lock.withLock {
      codexRunsBySessionID.values.flatMap(\.self).first { $0.runId == runID }
    }
  }
  func configuredAgentTui(id tuiID: String) -> AgentTuiSnapshot? {
    lock.withLock {
      agentTuisBySessionID.values.flatMap(\.self).first { $0.tuiId == tuiID }
    }
  }
  func dequeueConfiguredAgentTuiInputResponse(id tuiID: String) -> AgentTuiSnapshot? {
    lock.withLock {
      dequeueAgentTuiSnapshot(
        from: &agentTuiInputResponsesByID,
        tuiID: tuiID
      )
    }
  }
  func dequeueConfiguredAgentTuiReadSnapshot(id tuiID: String) -> AgentTuiSnapshot? {
    lock.withLock {
      dequeueAgentTuiSnapshot(
        from: &agentTuiReadSnapshotsByID,
        tuiID: tuiID
      )
    }
  }
  func recordCodexRun(_ run: CodexRunSnapshot) {
    lock.withLock {
      var runs = codexRunsBySessionID[run.sessionId] ?? []
      runs.removeAll { $0.runId == run.runId }
      runs.insert(run, at: 0)
      codexRunsBySessionID[run.sessionId] = runs
    }
  }
  func recordAgentTui(_ tui: AgentTuiSnapshot) {
    lock.withLock {
      var tuis = agentTuisBySessionID[tui.sessionId] ?? []
      tuis.removeAll { $0.tuiId == tui.tuiId }
      tuis.insert(tui, at: 0)
      agentTuisBySessionID[tui.sessionId] = tuis
    }
  }
  func configuredGlobalStreamEvents() -> [DaemonPushEvent] { lock.withLock { globalStreamEvents } }
  func configuredGlobalStreamError() -> (any Error)? { lock.withLock { globalStreamError } }
  func configuredSessionStreamEvents(for sessionID: String) -> [DaemonPushEvent] {
    lock.withLock { sessionStreamEventsBySessionID[sessionID] ?? [] }
  }
  func configuredSessionStreamError(for sessionID: String) -> (any Error)? {
    lock.withLock { sessionStreamErrorsBySessionID[sessionID] }
  }
  func shutdownCallCount() -> Int { lock.withLock { recordedShutdownCallCount } }
}
