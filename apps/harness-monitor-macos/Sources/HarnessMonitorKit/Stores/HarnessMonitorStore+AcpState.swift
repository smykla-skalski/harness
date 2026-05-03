import Foundation

/// Outcome of `HarnessMonitorStore.applyAcpAgent`.
///
/// Lets callers distinguish "applied to the active session" from "ignored
/// because the user has navigated away," so the success toast can stay honest
/// about the snapshot's visibility instead of relying on a magic Bool.
public enum AcpAgentApplyOutcome: Equatable, Sendable {
  case applied
  case droppedSessionMismatch
}

extension HarnessMonitorStore {
  @discardableResult
  func applyAcpAgent(_ snapshot: AcpAgentSnapshot) -> AcpAgentApplyOutcome {
    guard snapshot.sessionId == selectedSessionID else {
      HarnessMonitorLogger.store.warning(
        """
        applyAcpAgent dropped snapshot for inactive session \
        snapshotSession=\(snapshot.sessionId, privacy: .public) \
        selectedSession=\(self.selectedSessionID ?? "<nil>", privacy: .public) \
        agent=\(snapshot.agentId, privacy: .public) \
        acp=\(snapshot.acpId, privacy: .public)
        """
      )
      return .droppedSessionMismatch
    }
    noteAcpSessionActivity(sessionID: snapshot.sessionId)

    let pendingStandaloneBatches = standaloneAcpPermissionBatches.filter {
      $0.acpId == snapshot.acpId
    }
    standaloneAcpPermissionBatches.removeAll { $0.acpId == snapshot.acpId }
    selectedAcpAgents = upsertingAcpAgent(
      snapshot.withPermissionBatches(
        mergedPermissionBatches(
          primary: snapshot.pendingPermissionBatches,
          secondary: pendingStandaloneBatches,
          preferSecondary: false
        )
      ),
      into: selectedAcpAgents
    )
    reconcileAcpInspectSnapshot(with: snapshot)
    reconcileAcpInspectSyncState(
      sessionID: snapshot.sessionId,
      activeAgents: selectedAcpAgents
    )
    reconcilePresentedAcpPermissionBatch()
    reconcileAcpPermissionDecisions()
    return AcpAgentApplyOutcome.applied
  }

  func replaceAcpAgents(
    _ payload: AcpAgentsReconciledPayload,
    sampledAt: Date? = nil,
    allowAutoPresentation: Bool = true,
    shouldScheduleRecovery: Bool = true
  ) {
    guard payload.sessionId == selectedSessionID else {
      return
    }
    noteAcpSessionActivity(sessionID: payload.sessionId)
    let hadPresentedBatch = presentingAcpPermissionBatch != nil
    selectedAcpAgents =
      sortedAcpAgents(
        payload.agents.map { snapshot in
          let pendingStandaloneBatches = standaloneAcpPermissionBatches.filter {
            $0.acpId == snapshot.acpId
          }
          return snapshot.withPermissionBatches(
            mergedPermissionBatches(
              primary: snapshot.pendingPermissionBatches,
              secondary: pendingStandaloneBatches,
              preferSecondary: false
            )
          )
        }
      )
    standaloneAcpPermissionBatches.removeAll { $0.sessionId == payload.sessionId }
    if let inspect = payload.inspect {
      replaceAcpInspect(
        inspect,
        sessionID: payload.sessionId,
        sampledAt: sampledAt ?? .now,
        shouldScheduleRecovery: false
      )
    }
    reconcileAcpInspectState(
      sessionID: payload.sessionId,
      activeAgents: selectedAcpAgents
    )
    reconcileAcpInspectSyncState(
      sessionID: payload.sessionId,
      activeAgents: selectedAcpAgents,
      response: payload.inspect,
      sampledAt: sampledAt ?? .now,
      shouldScheduleRecovery: shouldScheduleRecovery
    )
    reconcilePresentedAcpPermissionBatch(
      allowAutoPresentation: allowAutoPresentation || hadPresentedBatch
    )
    reconcileAcpPermissionDecisions()
  }

  func replaceAcpInspect(
    _ response: AcpAgentInspectResponse,
    sessionID: String,
    sampledAt: Date,
    shouldScheduleRecovery: Bool = true
  ) {
    guard sessionID == selectedSessionID else {
      return
    }
    noteAcpSessionActivity(sessionID: sessionID, at: sampledAt)
    let nextSample = AcpInspectSample(
      sessionID: sessionID,
      sampledAt: sampledAt,
      agents: sortedAcpInspectSnapshots(
        response.agents.filter { $0.sessionId == sessionID }
      )
    )
    selectedAcpInspectState = nextSample
    reconcileAcpInspectSyncState(
      sessionID: sessionID,
      activeAgents: selectedAcpAgents,
      response: response,
      sampledAt: sampledAt,
      shouldScheduleRecovery: shouldScheduleRecovery
    )
  }

  func applyAcpEvents(_ payload: AcpEventBatchPayload, recordedAt: String) {
    guard payload.sessionId == selectedSessionID else {
      return
    }
    noteAcpSessionActivity(sessionID: payload.sessionId)
    let entries = payload.timelineEntries(
      fallbackRecordedAt: recordedAt,
      toolCallMetadata: acpToolCallTimelineMetadata(for: payload)
    )
    let visibleToolCallCount = Set(
      entries.compactMap { $0.toolCallTimelineEntryMetadata()?.rowID }
    ).count
    toolCallTimelineOverflowNotice =
      if payload.rawCount > payload.events.count {
        ToolCallTimelineOverflowNotice(
          sessionID: payload.sessionId,
          rawUpdateCount: payload.rawCount,
          displayedEventCount: visibleToolCallCount,
          recordedAt: recordedAt
        )
      } else {
        nil
      }
    liveToolCallAnnouncementRowIDs = Set(
      entries.compactMap { $0.toolCallTimelineEntryMetadata()?.rowID }
    )
    guard !entries.isEmpty else {
      return
    }
    applyAcpTimelineEntries(entries)
  }

  func applyAcpPermissionBatch(_ batch: AcpPermissionBatch) {
    guard batch.sessionId == selectedSessionID else {
      return
    }
    noteAcpSessionActivity(sessionID: batch.sessionId)
    let decisionID = AcpPermissionDecisionPayload.decisionID(for: batch.batchId)
    if acpPermissionTerminalOutcomesByID[decisionID] != nil {
      return
    }

    if !selectedAcpAgents.contains(where: { $0.acpId == batch.acpId }) {
      standaloneAcpPermissionBatches = upsertingAcpPermissionBatch(
        batch,
        into: standaloneAcpPermissionBatches
      )
      reconcilePresentedAcpPermissionBatch()
      reconcileAcpPermissionDecisions()
      return
    }
    selectedAcpAgents = selectedAcpAgents.map { snapshot in
      guard snapshot.acpId == batch.acpId else { return snapshot }
      return snapshot.withPermissionBatches(
        mergedPermissionBatches(
          primary: snapshot.pendingPermissionBatches,
          secondary: [batch],
          preferSecondary: false
        )
      )
    }
    reconcilePresentedAcpPermissionBatch()
    reconcileAcpPermissionDecisions()
  }

  func removeAcpPermissionBatch(
    _ batch: AcpPermissionBatch,
    reason: AcpPermissionBatchRemovalReason = .resolved
  ) {
    let decisionID = AcpPermissionDecisionPayload.decisionID(for: batch.batchId)
    noteAcpSessionActivity(sessionID: batch.sessionId)
    let isTerminalRemoval = reason == .timeout || reason == .shutdown
    if isTerminalRemoval {
      let outcome = terminalOutcome(for: reason)
      acpPermissionTerminalOutcomesByID[decisionID] = outcome
    } else {
      acpPermissionTerminalOutcomesByID.removeValue(forKey: decisionID)
    }
    if reason == .timeout {
      let inserted = acpPermissionPendingTimeoutDecisionIDs.insert(decisionID).inserted
      if inserted {
        scheduleAcpPermissionDeadlineResolution(for: batch, decisionID: decisionID)
      }
    } else if reason == .shutdown {
      let inserted = acpPermissionPendingShutdownDecisionIDs.insert(decisionID).inserted
      if inserted {
        scheduleAcpPermissionShutdownResolution(for: batch, decisionID: decisionID)
      }
    } else {
      acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
      acpPermissionPendingShutdownDecisionIDs.remove(decisionID)
    }
    standaloneAcpPermissionBatches.removeAll { $0.batchId == batch.batchId }
    selectedAcpAgents = selectedAcpAgents.map { snapshot in
      guard snapshot.acpId == batch.acpId else { return snapshot }
      let batches = snapshot.pendingPermissionBatches.filter { $0.batchId != batch.batchId }
      return snapshot.withPermissionBatches(batches)
    }
    if presentingAcpPermissionBatch?.batchId == batch.batchId {
      presentingAcpPermissionBatch = nil
    }
    reconcilePresentedAcpPermissionBatch()
    if isTerminalRemoval {
      invalidateAcpPermissionDecisionSync()
      return
    }
    reconcileAcpPermissionDecisions()
    scheduleAcpPermissionDecisionSync(staleDecisionIDs: [decisionID])
  }

  func resetSelectedAcpAgents() {
    selectedAcpAgents = []
    selectedAcpInspectState = nil
    selectedAcpInspectSyncEntries = [:]
    cancelAcpInspectRecovery()
    liveToolCallAnnouncementRowIDs = []
    toolCallTimelineOverflowNotice = nil
    standaloneAcpPermissionBatches = []
    presentingAcpPermissionBatch = nil
    resolvingAcpPermissionBatchID = nil
    acpPermissionPayloadsByDecisionID = [:]
    acpPermissionResolutionStateByDecisionID = [:]
    acpPermissionPendingTimeoutDecisionIDs = []
    acpPermissionPendingShutdownDecisionIDs = []
    acpPermissionTerminalOutcomesByID = [:]
    invalidateAcpPermissionDecisionSync()
  }
}
