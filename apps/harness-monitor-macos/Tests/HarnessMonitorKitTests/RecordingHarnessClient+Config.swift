import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func recordedCalls() -> [Call] {
    calls
  }

  func configureHealthDelay(_ delay: Duration?) {
    lock.withLock {
      _healthDelay = delay
    }
  }

  func configureTransportLatencyMs(_ latencyMs: Int?) {
    lock.withLock {
      _transportLatencyMs = latencyMs
    }
  }

  func configureTransportLatencyError(_ error: (any Error)?) {
    lock.withLock {
      _transportLatencyError = error
    }
  }

  func configureDiagnosticsDelay(_ delay: Duration?) {
    lock.withLock {
      _diagnosticsDelay = delay
    }
  }

  func configureMutationDelay(_ delay: Duration?) {
    lock.withLock {
      _mutationDelay = delay
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

      _projectSummaries = orderedProjectIDs.compactMap { projectID in
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
      _sessionSummaries = summaries
      _sessionDetailsByID = detailsByID
      _timelinesBySessionID = timelinesBySessionID
    }
  }

  func configureDetailDelay(_ delay: Duration?, for sessionID: String) {
    lock.withLock {
      if let delay {
        _detailDelays[sessionID] = delay
      } else {
        _detailDelays.removeValue(forKey: sessionID)
      }
    }
  }

  func configureSessionDetailError(_ error: (any Error)?, for sessionID: String) {
    lock.withLock {
      if let error {
        _sessionDetailErrorsByID[sessionID] = error
      } else {
        _sessionDetailErrorsByID.removeValue(forKey: sessionID)
      }
    }
  }

  func configuredSessionDetailError(for sessionID: String) -> (any Error)? {
    lock.withLock { _sessionDetailErrorsByID[sessionID] }
  }

  func configureTimelineError(_ error: (any Error)?, for sessionID: String) {
    lock.withLock {
      if let error {
        _timelineErrorsByID[sessionID] = error
      } else {
        _timelineErrorsByID.removeValue(forKey: sessionID)
      }
    }
  }

  func configuredTimelineError(for sessionID: String) -> (any Error)? {
    lock.withLock { _timelineErrorsByID[sessionID] }
  }

  func configureTimelineDelay(_ delay: Duration?, for sessionID: String) {
    lock.withLock {
      if let delay {
        _timelineDelays[sessionID] = delay
      } else {
        _timelineDelays.removeValue(forKey: sessionID)
      }
    }
  }

  func configureGlobalStream(
    events: [DaemonPushEvent],
    error: (any Error)? = nil
  ) {
    lock.withLock {
      _globalStreamEvents = events
      _globalStreamError = error
    }
  }

  func configureSessionStream(
    events: [DaemonPushEvent],
    error: (any Error)? = nil,
    for sessionID: String
  ) {
    lock.withLock {
      _sessionStreamEventsByID[sessionID] = events
      if let error {
        _sessionStreamErrorsByID[sessionID] = error
      } else {
        _sessionStreamErrorsByID.removeValue(forKey: sessionID)
      }
    }
  }

  func configureCodexRuns(_ runs: [CodexRunSnapshot], for sessionID: String) {
    lock.withLock {
      _codexRunsBySessionID[sessionID] = runs
    }
  }

  func configureAgentTuis(_ tuis: [AgentTuiSnapshot], for sessionID: String) {
    lock.withLock {
      _agentTuisBySessionID[sessionID] = tuis
    }
  }

  func configureAgentTuiInputResponses(_ snapshots: [AgentTuiSnapshot], for tuiID: String) {
    lock.withLock {
      _agentTuiInputResponsesByID[tuiID] = snapshots
    }
  }

  func configureAgentTuiReadSnapshots(_ snapshots: [AgentTuiSnapshot], for tuiID: String) {
    lock.withLock {
      _agentTuiReadSnapshotsByID[tuiID] = snapshots
    }
  }

  func configureCodexStartError(_ error: (any Error)?) {
    lock.withLock {
      _codexStartError = error
      _queuedCodexStartErrors = []
    }
  }

  func configureCodexStartErrors(_ errors: [any Error]) {
    lock.withLock {
      _queuedCodexStartErrors = errors
      _codexStartError = nil
    }
  }

  func configureAgentTuiStartError(_ error: (any Error)?) {
    lock.withLock { _agentTuiStartError = error }
  }

  func configureHostBridgeReconfigureError(_ error: (any Error)?) {
    lock.withLock { _hostBridgeReconfigureError = error }
  }

  func configureHostBridgeStatusReport(_ report: BridgeStatusReport) {
    lock.withLock { _hostBridgeStatusReport = report }
  }

  func configuredCodexStartError() -> (any Error)? {
    lock.withLock { _codexStartError }
  }

  func dequeueConfiguredCodexStartError() -> (any Error)? {
    lock.withLock {
      guard let error = _queuedCodexStartErrors.first else {
        return _codexStartError
      }
      _queuedCodexStartErrors.removeFirst()
      return error
    }
  }

  func configuredAgentTuiStartError() -> (any Error)? {
    lock.withLock { _agentTuiStartError }
  }

  func configuredHostBridgeReconfigureError() -> (any Error)? {
    lock.withLock { _hostBridgeReconfigureError }
  }

  func configuredHostBridgeStatusReport() -> BridgeStatusReport {
    lock.withLock { _hostBridgeStatusReport }
  }

  func configuredHealthDelay() -> Duration? { lock.withLock { _healthDelay } }
  func configuredTransportLatencyMs() -> Int? { lock.withLock { _transportLatencyMs } }
  func configuredTransportLatencyError() -> (any Error)? {
    lock.withLock { _transportLatencyError }
  }
  func configuredDiagnosticsDelay() -> Duration? { lock.withLock { _diagnosticsDelay } }
  func configuredMutationDelay() -> Duration? { lock.withLock { _mutationDelay } }
  func configuredProjects() -> [ProjectSummary]? { lock.withLock { _projectSummaries } }
  func configuredSessions() -> [SessionSummary]? { lock.withLock { _sessionSummaries } }
  func configuredSessionDetail(id: String) -> SessionDetail? {
    lock.withLock { _sessionDetailsByID[id] }
  }
  func configuredDetailDelay(for sessionID: String) -> Duration? {
    lock.withLock { _detailDelays[sessionID] }
  }
  func sessionDetailScopes(for sessionID: String) -> [String?] {
    lock.withLock { _sessionDetailScopesByID[sessionID] ?? [] }
  }
  func configuredTimeline(for sessionID: String) -> [TimelineEntry]? {
    lock.withLock { _timelinesBySessionID[sessionID] }
  }
  func timelineScopes(for sessionID: String) -> [TimelineScope] {
    lock.withLock { _timelineScopesBySessionID[sessionID] ?? [] }
  }
  func configuredTimelineBatches(for sessionID: String) -> [[TimelineEntry]]? {
    lock.withLock { _timelineBatchesBySessionID[sessionID] }
  }
  func configuredTimelineDelay(for sessionID: String) -> Duration? {
    lock.withLock { _timelineDelays[sessionID] }
  }
  func configuredTimelineBatchDelay(for sessionID: String) -> Duration? {
    lock.withLock { _timelineBatchDelaysBySessionID[sessionID] }
  }
  func configuredCodexRuns(for sessionID: String) -> [CodexRunSnapshot] {
    lock.withLock { _codexRunsBySessionID[sessionID] ?? [] }
  }
  func configuredAgentTuis(for sessionID: String) -> [AgentTuiSnapshot] {
    lock.withLock { _agentTuisBySessionID[sessionID] ?? [] }
  }
  func configuredCodexRun(id runID: String) -> CodexRunSnapshot? {
    lock.withLock {
      _codexRunsBySessionID.values.flatMap(\.self).first { $0.runId == runID }
    }
  }
  func configuredAgentTui(id tuiID: String) -> AgentTuiSnapshot? {
    lock.withLock {
      _agentTuisBySessionID.values.flatMap(\.self).first { $0.tuiId == tuiID }
    }
  }
  func dequeueConfiguredAgentTuiInputResponse(id tuiID: String) -> AgentTuiSnapshot? {
    lock.withLock {
      dequeueAgentTuiSnapshot(
        from: &_agentTuiInputResponsesByID,
        tuiID: tuiID
      )
    }
  }
  func dequeueConfiguredAgentTuiReadSnapshot(id tuiID: String) -> AgentTuiSnapshot? {
    lock.withLock {
      dequeueAgentTuiSnapshot(
        from: &_agentTuiReadSnapshotsByID,
        tuiID: tuiID
      )
    }
  }
  func recordCodexRun(_ run: CodexRunSnapshot) {
    lock.withLock {
      var runs = _codexRunsBySessionID[run.sessionId] ?? []
      runs.removeAll { $0.runId == run.runId }
      runs.insert(run, at: 0)
      _codexRunsBySessionID[run.sessionId] = runs
    }
  }
  func recordAgentTui(_ tui: AgentTuiSnapshot) {
    lock.withLock {
      var tuis = _agentTuisBySessionID[tui.sessionId] ?? []
      tuis.removeAll { $0.tuiId == tui.tuiId }
      tuis.insert(tui, at: 0)
      _agentTuisBySessionID[tui.sessionId] = tuis
    }
  }
  func configuredGlobalStreamEvents() -> [DaemonPushEvent] { lock.withLock { _globalStreamEvents } }
  func configuredGlobalStreamError() -> (any Error)? { lock.withLock { _globalStreamError } }
  func configuredSessionStreamEvents(for sessionID: String) -> [DaemonPushEvent] {
    lock.withLock { _sessionStreamEventsByID[sessionID] ?? [] }
  }
  func configuredSessionStreamError(for sessionID: String) -> (any Error)? {
    lock.withLock { _sessionStreamErrorsByID[sessionID] }
  }
  func shutdownCallCount() -> Int { lock.withLock { _shutdownCallCount } }
}
