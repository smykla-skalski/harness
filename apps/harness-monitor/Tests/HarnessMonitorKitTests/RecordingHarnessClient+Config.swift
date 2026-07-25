import Foundation

@testable import HarnessMonitorKit

extension RecordingHarnessClient {
  func recordedCalls() -> [Call] {
    calls
  }

  func clearRecordedCalls() {
    lock.withLock { callsStorage.removeAll() }
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

  func configureTaskBoardItemsErrors(_ errors: [any Error]) {
    lock.withLock {
      queuedTaskBoardItemsErrors = errors
    }
  }

  func configureTaskBoardProjectsErrors(_ errors: [any Error]) {
    lock.withLock {
      queuedTaskBoardProjectsErrors = errors
    }
  }

  func configureDeliverTaskBoardDispatchErrors(_ errors: [any Error]) {
    lock.withLock {
      queuedDeliverTaskBoardDispatchErrors = errors
    }
  }

  /// Items the daemon reports as holding a step-mode delivery that is waiting
  /// to be claimed.
  func configureHeldTaskBoardDispatches(_ itemIDs: [String]) {
    lock.withLock {
      heldTaskBoardDispatchItemIDs = itemIDs
    }
  }

  /// Reserve failures the daemon returns for an item: dispatch reports the item
  /// in `failures` (with this message) instead of `applied`, and holds nothing.
  func configureTaskBoardDispatchFailure(itemID: String, message: String) {
    lock.withLock {
      taskBoardDispatchFailureMessages[itemID] = message
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

  func configureTaskBoardItemSnapshots(_ snapshots: [[TaskBoardItem]]) {
    lock.withLock {
      queuedTaskBoardItemSnapshots = snapshots
    }
  }

  func configureTaskBoardSync(
    summary: TaskBoardSyncSummary,
    importedItems: [TaskBoardItem]? = nil
  ) {
    lock.withLock {
      taskBoardSyncStub.summary = summary
      taskBoardSyncStub.importedItems = importedItems
      taskBoardSyncStub.error = nil
    }
  }

  func configureTaskBoardSyncError(_ error: any Error) {
    lock.withLock {
      taskBoardSyncStub.error = error
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

  func configureTaskBoardCreateError(_ error: (any Error)?) {
    lock.withLock {
      taskBoardCreateError = error
    }
  }

  func configureTaskBoardUpdateError(_ error: (any Error)?) {
    lock.withLock {
      taskBoardUpdateError = error
    }
  }

  func configureTaskUpdateError(_ error: (any Error)?) {
    lock.withLock {
      taskUpdateError = error
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

}
