import Foundation

extension HarnessMonitorStore {
  static let streamReconnectDelays: [Duration] = [
    .milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8),
  ]
  static let streamReconnectMaxAttempts = 6

  func startGlobalStream(using client: any HarnessMonitorClientProtocol) {
    stopGlobalStream()
    guard maintainsLiveDaemonObservation else {
      return
    }
    globalStreamTask = Task { @MainActor [weak self] in
      var state = GlobalStreamPassState()
      while !Task.isCancelled {
        // The store is taken for one pass and let go again before the backoff.
        // These loops re-bootstrap the connection for as long as they run, and
        // the recovery they schedule starts them again, so a reference held
        // across the wait would keep a store nobody owns any more reconnecting
        // for the life of the process.
        let outcome: StreamPassOutcome
        if let store = self {
          outcome = await store.runGlobalStreamPass(using: client, state: &state)
        } else {
          return
        }
        guard case .retry(let delay) = outcome else {
          return
        }
        try? await Task.sleep(for: delay)
      }
    }
  }

  func startSessionStream(using client: any HarnessMonitorClientProtocol, sessionID: String) {
    guard maintainsLiveDaemonObservation else {
      stopSessionStream()
      return
    }
    subscribedSessionIDs = [sessionID]
    stopSessionStream(resetSubscriptions: false)
    sessionStreamTask = Task { @MainActor [weak self] in
      var attempt = 0
      while !Task.isCancelled {
        let outcome: StreamPassOutcome
        if let store = self {
          outcome = await store.runSessionStreamPass(
            using: client,
            sessionID: sessionID,
            attempt: &attempt
          )
        } else {
          return
        }
        guard case .retry(let delay) = outcome else {
          return
        }
        try? await Task.sleep(for: delay)
      }
    }
  }

  func applyGlobalPushEvent(_ event: DaemonPushEvent) {
    if applyManagedAgentPushEvent(event) {
      scheduleSupervisorTick(reason: "global-managed-agent")
      return
    }

    if applyGlobalSessionPushEvent(event) {
      scheduleSupervisorTick(reason: "global-session")
      return
    }
    applyGlobalNonSessionPushEvent(event)
  }

  func handleGlobalSessionUpdate(
    sessionID: String,
    payload: SessionUpdatedPayload
  ) {
    guard !shouldIgnoreLocallyRemovedSession(sessionID) else {
      return
    }
    let detail = sessionDetailPreservingSelectedExtensions(
      sessionID: sessionID,
      detail: payload.detail,
      extensionsPending: payload.extensionsPending == true
    )
    if payload.extensionsPending != true {
      isExtensionsLoading = false
    }
    guard sessionID == selectedSessionID else {
      applySessionSummaryUpdate(detail.session)
      if let timeline = payload.timeline {
        scheduleSessionDetailCacheWrite(
          detail,
          timeline: timeline,
          timelineWindow: TimelineWindowResponse.fallbackMetadata(for: timeline),
          markViewed: false
        )
      } else {
        scheduleSessionDetailCacheWrite(
          detail,
          timeline: [],
          markViewed: false,
          preservesTimeline: true
        )
      }
      return
    }
    let timeline = payload.timeline ?? self.timeline
    let resolvedTimelineWindow = mergedTimelineWindowAfterPush(
      payloadTimeline: payload.timeline
    )
    applySelectedSessionSnapshot(
      sessionID: sessionID,
      detail: detail,
      timeline: timeline,
      timelineWindow: resolvedTimelineWindow,
      clearBurstState: payload.timeline != nil,
      showingCachedData: false,
      cancelPendingTimelineRefresh: payload.timeline != nil
    )
    if let freshTimeline = payload.timeline {
      scheduleSelectedSessionCacheWrite(
        detail,
        timeline: freshTimeline,
        timelineWindow: resolvedTimelineWindow
          ?? TimelineWindowResponse.fallbackMetadata(for: freshTimeline)
      )
    } else if let client {
      scheduleSessionPushFallback(using: client, sessionID: sessionID)
    }
  }

  func applySessionPushEvent(_ event: DaemonPushEvent) {
    if applyManagedAgentPushEvent(event) {
      scheduleSupervisorTick(reason: "session-managed-agent")
      return
    }

    var shouldTickSupervisor = false
    switch event.kind {
    case .ready, .sessionsUpdated, .sessionsUpdatedDelta, .logLevelChanged, .unknown:
      break
    case .sessionUpdated(let payload):
      handleSelectedSessionPushUpdate(event: event, payload: payload)
      shouldTickSupervisor = true
    case .sessionExtensions(let payload):
      applySessionExtensions(payload)
      shouldTickSupervisor = true
    case .codexRunUpdated, .codexApprovalRequested, .agentTuiUpdated, .acpAgentUpdated,
      .acpInspect, .acpAgentsReconciled, .acpProcessIncident, .acpBridgeResyncIncident,
      .acpEvents, .acpPermissionBatch, .acpPermissionBatchRemoved, .githubDataChanged,
      .taskBoardUpdated, .auditEvent:
      break
    case .reviewsLocalCloneProgress(let progress):
      applyLocalCloneProgress(progress)
    case .taskBoardWorkingCopyProgress(let progress):
      applyWorkingCopyProgress(progress)
    }
    if shouldTickSupervisor {
      scheduleSupervisorTick(reason: "session-update")
    }
  }

  private func handleSelectedSessionPushUpdate(
    event: DaemonPushEvent,
    payload: SessionUpdatedPayload
  ) {
    guard let sessionID = event.sessionId else {
      return
    }
    guard !shouldIgnoreLocallyRemovedSession(sessionID) else {
      return
    }
    let detail = sessionDetailPreservingSelectedExtensions(
      sessionID: sessionID,
      detail: payload.detail,
      extensionsPending: payload.extensionsPending == true
    )
    if payload.extensionsPending != true {
      isExtensionsLoading = false
    }
    let timeline = payload.timeline ?? self.timeline
    let resolvedTimelineWindow = mergedTimelineWindowAfterPush(
      payloadTimeline: payload.timeline
    )
    applySelectedSessionSnapshot(
      sessionID: sessionID,
      detail: detail,
      timeline: timeline,
      timelineWindow: resolvedTimelineWindow,
      clearBurstState: payload.timeline != nil,
      showingCachedData: false,
      cancelPendingTimelineRefresh: payload.timeline != nil
    )
    if let freshTimeline = payload.timeline {
      scheduleSelectedSessionCacheWrite(
        detail,
        timeline: freshTimeline,
        timelineWindow: resolvedTimelineWindow
          ?? TimelineWindowResponse.fallbackMetadata(for: freshTimeline)
      )
    } else if let client {
      scheduleSessionPushFallback(using: client, sessionID: sessionID)
    }
  }

  func applyGlobalPushEventFromStream(_ event: DaemonPushEvent) async {
    if await applyManagedAgentPushEventFromStream(event) {
      scheduleSupervisorTick(reason: "global-managed-agent")
      return
    }
    if await applyGlobalDataPushEventFromStream(event) { return }
    applyGlobalPushEvent(event)
  }

  func applySessionPushEventFromStream(_ event: DaemonPushEvent) async {
    if await applyManagedAgentPushEventFromStream(event) {
      scheduleSupervisorTick(reason: "session-managed-agent")
      return
    }
    applySessionPushEvent(event)
  }

  @discardableResult
  private func applyManagedAgentPushEvent(_ event: DaemonPushEvent) -> Bool {
    if applyCoreManagedAgentPushEvent(event) {
      return true
    }
    return applyAcpManagedAgentPushEvent(event)
  }

  @discardableResult
  private func applyManagedAgentPushEventFromStream(_ event: DaemonPushEvent) async -> Bool {
    if applyCoreManagedAgentPushEvent(event) {
      return true
    }
    return await applyAcpManagedAgentPushEventFromStream(event)
  }

  @discardableResult
  private func applyCoreManagedAgentPushEvent(_ event: DaemonPushEvent) -> Bool {
    switch event.kind {
    case .codexRunUpdated(let run):
      applyCodexRun(run)
    case .codexApprovalRequested(let payload):
      applyCodexApprovalRequested(payload)
    case .agentTuiUpdated(let tui):
      applyAgentTui(tui)
    default:
      return false
    }
    return true
  }

  @discardableResult
  private func applyAcpManagedAgentPushEvent(_ event: DaemonPushEvent) -> Bool {
    switch event.kind {
    case .acpAgentUpdated(let snapshot):
      applyAcpAgent(snapshot)
    case .acpInspect(let response):
      guard let sessionID = event.sessionId else {
        return false
      }
      replaceAcpInspect(
        response,
        sessionID: sessionID,
        sampledAt: Self.acpInspectSampledAt(from: event.recordedAt)
      )
    case .acpAgentsReconciled(let payload):
      replaceAcpAgents(
        payload,
        sampledAt: Self.acpInspectSampledAt(from: event.recordedAt)
      )
    case .acpEvents(let payload):
      applyAcpEvents(payload, recordedAt: event.recordedAt)
    case .acpProcessIncident(let payload):
      applyAcpProcessIncident(payload, recordedAt: event.recordedAt, sessionID: event.sessionId)
    case .acpBridgeResyncIncident(let payload):
      applyAcpBridgeResyncIncident(
        payload,
        recordedAt: event.recordedAt,
        sessionID: event.sessionId
      )
    case .acpPermissionBatch(let batch):
      applyAcpPermissionBatch(batch)
    case .acpPermissionBatchRemoved(let removal):
      removeAcpPermissionBatch(removal.batch, reason: removal.reason)
    default:
      return false
    }
    return true
  }

  @discardableResult
  private func applyAcpManagedAgentPushEventFromStream(_ event: DaemonPushEvent) async -> Bool {
    switch event.kind {
    case .acpAgentUpdated(let snapshot):
      await applyAcpAgentFromStream(snapshot)
    case .acpInspect(let response):
      guard let sessionID = event.sessionId else {
        return false
      }
      await replaceAcpInspectAsync(
        response,
        sessionID: sessionID,
        sampledAt: Self.acpInspectSampledAt(from: event.recordedAt)
      )
    case .acpAgentsReconciled(let payload):
      await replaceAcpAgentsFromStream(
        payload,
        sampledAt: Self.acpInspectSampledAt(from: event.recordedAt)
      )
    case .acpEvents(let payload):
      await applyAcpEventsFromStream(payload, recordedAt: event.recordedAt)
    case .acpPermissionBatch(let batch):
      await applyAcpPermissionBatchFromStream(batch)
    case .acpPermissionBatchRemoved(let removal):
      await removeAcpPermissionBatchFromStream(removal.batch, reason: removal.reason)
    default:
      return applyAcpManagedAgentPushEvent(event)
    }
    return true
  }
}
