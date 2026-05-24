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
    case .unknown:
      break
    case .sessionsUpdated, .sessionUpdated, .sessionExtensions:
      break
    }
  }
}
