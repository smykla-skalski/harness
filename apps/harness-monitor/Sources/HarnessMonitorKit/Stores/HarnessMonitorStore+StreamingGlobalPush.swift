extension HarnessMonitorStore {
  func applyGlobalSessionPushEvent(_ event: DaemonPushEvent) -> Bool {
    switch event.kind {
    case .sessionsUpdated(let payload):
      scheduleSessionIndexSnapshotApply(
        projects: payload.projects,
        sessions: payload.sessions,
        refreshSelectedSession: true
      )
      return true
    case .sessionUpdated(let payload):
      guard let sessionID = event.sessionId else {
        return false
      }
      handleGlobalSessionUpdate(sessionID: sessionID, payload: payload)
      return true
    case .sessionExtensions(let payload):
      applySessionExtensions(payload)
      return true
    case .sessionsUpdatedDelta(let payload):
      scheduleSessionIndexSnapshotApply(
        projects: payload.projects,
        sessions: mergedSessionsApplyingDelta(payload),
        refreshSelectedSession: true
      )
      return true
    default:
      return false
    }
  }

  func applyGlobalNonSessionPushEvent(_ event: DaemonPushEvent) {
    switch event.kind {
    case .ready:
      break
    case .logLevelChanged(let response):
      daemonLogLevel = response.level
    case .codexRunUpdated, .codexApprovalRequested, .agentTuiUpdated, .acpAgentUpdated,
      .acpInspect, .acpAgentsReconciled, .acpProcessIncident, .acpBridgeResyncIncident,
      .acpEvents, .acpPermissionBatch, .acpPermissionBatchRemoved:
      break
    case .reviewsLocalCloneProgress(let progress):
      applyLocalCloneProgress(progress)
    case .githubDataChanged(let payload):
      applyGitHubDataChange(payload)
    case .taskBoardUpdated(let payload):
      applyTaskBoardChange(payload)
    case .auditEvent(let event):
      applyApplicationAuditEvent(event)
    case .unknown:
      break
    case .sessionsUpdated, .sessionsUpdatedDelta, .sessionUpdated, .sessionExtensions:
      break
    }
  }

  private func applyGitHubDataChange(_ payload: GitHubDataChangedPayload) {
    if contentUI.dashboard.latestGitHubDataChange != payload {
      contentUI.dashboard.latestGitHubDataChange = payload
    }
    if contentUI.dashboard.githubDataRevision != payload.revision {
      contentUI.dashboard.githubDataRevision = payload.revision
    }
  }

  private func applyTaskBoardChange(_ payload: TaskBoardUpdatedPayload) {
    if contentUI.dashboard.taskBoardRevision != payload.revision {
      contentUI.dashboard.taskBoardRevision = payload.revision
    }
    mergeTaskBoardAutomationSnapshot(payload.automation)
  }

  func mergedSessionsApplyingDelta(
    _ payload: SessionsUpdatedDeltaPayload
  ) -> [SessionSummary] {
    let removedIDs = Set(payload.removed)
    var changedByID: [String: SessionSummary] = [:]
    for summary in payload.changed {
      changedByID[summary.sessionId] = summary
    }
    var merged: [SessionSummary] = []
    merged.reserveCapacity(sessions.count + payload.changed.count)
    var consumed: Set<String> = []
    for existing in sessions where !removedIDs.contains(existing.sessionId) {
      if let updated = changedByID[existing.sessionId] {
        merged.append(updated)
        consumed.insert(existing.sessionId)
      } else {
        merged.append(existing)
      }
    }
    for summary in payload.changed where !consumed.contains(summary.sessionId) {
      merged.append(changedByID[summary.sessionId] ?? summary)
      consumed.insert(summary.sessionId)
    }
    return merged
  }
}
