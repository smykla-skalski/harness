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

  func configureDiagnosticsReport(_ report: DaemonDiagnosticsReport?) {
    lock.withLock {
      diagnosticsReportOverride = report
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

  func configureArchiveSessionError(_ error: (any Error)?) {
    lock.withLock {
      archiveSessionError = error
    }
  }

  func configureResolvedAcpSnapshot(_ snapshot: AcpAgentSnapshot, for agentID: String) {
    lock.withLock {
      resolvedAcpSnapshotsByAgentID[agentID] = snapshot
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

  func configureTaskBoardItems(_ items: [TaskBoardItem]) {
    lock.withLock {
      taskBoardItemsStorage = items
    }
  }

  func configureTaskBoardSync(
    summary: TaskBoardSyncSummary,
    importedItems: [TaskBoardItem]? = nil
  ) {
    lock.withLock {
      taskBoardSyncSummaryStorage = summary
      taskBoardItemsAfterSyncStorage = importedItems
    }
  }

  func configureTaskBoardAudit(_ summary: TaskBoardAuditSummary?) {
    lock.withLock {
      taskBoardAuditSummaryStorage = summary
    }
  }

  func configureTaskBoardProjects(_ projects: [TaskBoardProjectSummary]?) {
    lock.withLock {
      taskBoardProjectSummariesStorage = projects
    }
  }

  func configureTaskBoardMachines(_ machines: [TaskBoardMachineSummary]?) {
    lock.withLock {
      taskBoardMachineSummariesStorage = machines
    }
  }

  func configureTaskBoardUpdateError(_ error: (any Error)?) {
    lock.withLock {
      taskBoardUpdateError = error
    }
  }

  func configureTaskBoardRuntimeConfigError(_ error: (any Error)?) {
    lock.withLock {
      taskBoardRuntimeConfigError = error
    }
  }

  func configureTaskBoardOrchestratorSettingsError(_ error: (any Error)?) {
    lock.withLock {
      taskBoardOrchestratorSettingsError = error
    }
  }

  func configureTaskBoardGitHubTokensSyncError(_ error: (any Error)?) {
    lock.withLock {
      taskBoardGitHubTokensSyncError = error
    }
  }

  func configureTaskBoardTodoistTokenSyncError(_ error: (any Error)?) {
    lock.withLock {
      taskBoardTodoistTokenSyncError = error
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

}
