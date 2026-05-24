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
  func advanceAcpRuntimeStateGeneration() -> UInt64 {
    acpRuntimeStateGeneration &+= 1
    return acpRuntimeStateGeneration
  }

  func isCurrentAcpRuntimeStateGeneration(_ generation: UInt64) -> Bool {
    acpRuntimeStateGeneration == generation
  }

  @discardableResult
  func applyAcpAgent(_ snapshot: AcpAgentSnapshot) -> AcpAgentApplyOutcome {
    guard !shouldIgnoreLocallyRemovedSession(snapshot.sessionId) else {
      return .droppedSessionMismatch
    }
    guard snapshot.sessionId == selectedSessionID else {
      HarnessMonitorLogger.store.warning(
        """
        applyAcpAgent dropped snapshot for inactive session \
        snapshotSession=\(snapshot.sessionId, privacy: .public) \
        selectedSession=\(self.selectedSessionID ?? "<nil>", privacy: .public) \
        sessionAgent=\(snapshot.sessionAgentID, privacy: .public) \
        managedAgent=\(snapshot.managedAgentID, privacy: .public)
        """
      )
      return .droppedSessionMismatch
    }
    advanceAcpRuntimeStateGeneration()
    noteAcpSessionActivity(sessionID: snapshot.sessionId)
    let staleRestartDecisionIDs = staleDecisionIDsForRestartedAcpRuntime(
      replacedBy: snapshot
    )

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
    reattributeAcpTranscriptEntries(using: selectedAcpAgents)
    reattributeAcpTimelineEntries(using: selectedAcpAgents)
    reconcileAcpInspectSnapshot(with: snapshot)
    reconcileAcpInspectSyncState(
      sessionID: snapshot.sessionId,
      activeAgents: selectedAcpAgents
    )
    reconcilePresentedAcpPermissionBatch()
    reconcileAcpPermissionDecisions(extraStaleDecisionIDs: staleRestartDecisionIDs)
    return AcpAgentApplyOutcome.applied
  }

  @discardableResult
  func applyAcpAgentFromStream(_ snapshot: AcpAgentSnapshot) async -> AcpAgentApplyOutcome {
    guard !shouldIgnoreLocallyRemovedSession(snapshot.sessionId) else {
      return .droppedSessionMismatch
    }
    guard snapshot.sessionId == selectedSessionID else {
      HarnessMonitorLogger.store.warning(
        """
        applyAcpAgentFromStream dropped snapshot for inactive session \
        snapshotSession=\(snapshot.sessionId, privacy: .public) \
        selectedSession=\(self.selectedSessionID ?? "<nil>", privacy: .public) \
        sessionAgent=\(snapshot.sessionAgentID, privacy: .public) \
        managedAgent=\(snapshot.managedAgentID, privacy: .public)
        """
      )
      return .droppedSessionMismatch
    }
    let generation = advanceAcpRuntimeStateGeneration()
    noteAcpSessionActivity(sessionID: snapshot.sessionId)
    let output = await acpRuntimeWorker.agentUpdate(
      snapshot: snapshot,
      currentAgents: selectedAcpAgents,
      standalonePermissionBatches: standaloneAcpPermissionBatches,
      currentInspectSample: selectedAcpInspectState,
      currentInspectSyncEntries: selectedAcpInspectSyncEntries
    )
    guard
      snapshot.sessionId == selectedSessionID,
      isCurrentAcpRuntimeStateGeneration(generation),
      !Task.isCancelled
    else {
      return .droppedSessionMismatch
    }
    standaloneAcpPermissionBatches = output.standalonePermissionBatches
    selectedAcpAgents = output.selectedAgents
    selectedAcpInspectState = output.inspectSample
    selectedAcpInspectSyncEntries = output.inspectSyncEntries
    reattributeAcpTranscriptEntries(using: selectedAcpAgents)
    reattributeAcpTimelineEntries(using: selectedAcpAgents)
    finishAcpInspectSyncReconciliation(
      sessionID: snapshot.sessionId,
      hasRecoverableMissingEntries: output.hasRecoverableMissingInspectEntries,
      shouldScheduleRecovery: true
    )
    reconcilePresentedAcpPermissionBatch()
    reconcileAcpPermissionDecisions(extraStaleDecisionIDs: output.staleRestartDecisionIDs)
    return .applied
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
    advanceAcpRuntimeStateGeneration()
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
    reattributeAcpTranscriptEntries(using: selectedAcpAgents)
    reattributeAcpTimelineEntries(using: selectedAcpAgents)
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

  func replaceAcpAgentsFromStream(
    _ payload: AcpAgentsReconciledPayload,
    sampledAt: Date? = nil,
    allowAutoPresentation: Bool = true,
    shouldScheduleRecovery: Bool = true
  ) async {
    guard payload.sessionId == selectedSessionID else {
      return
    }
    let generation = advanceAcpRuntimeStateGeneration()
    let sampledAt = sampledAt ?? Date()
    noteAcpSessionActivity(sessionID: payload.sessionId)
    let hadPresentedBatch = presentingAcpPermissionBatch != nil
    let output = await acpRuntimeWorker.agentsReplacement(
      payload: payload,
      sampledAt: sampledAt,
      standalonePermissionBatches: standaloneAcpPermissionBatches,
      currentInspectSample: selectedAcpInspectState,
      currentInspectSyncEntries: selectedAcpInspectSyncEntries
    )
    guard
      payload.sessionId == selectedSessionID,
      isCurrentAcpRuntimeStateGeneration(generation),
      !Task.isCancelled
    else {
      return
    }
    standaloneAcpPermissionBatches = output.standalonePermissionBatches
    selectedAcpAgents = output.selectedAgents
    selectedAcpInspectState = output.inspectSample
    selectedAcpInspectSyncEntries = output.inspectSyncEntries
    reattributeAcpTranscriptEntries(using: selectedAcpAgents)
    reattributeAcpTimelineEntries(using: selectedAcpAgents)
    finishAcpInspectSyncReconciliation(
      sessionID: payload.sessionId,
      hasRecoverableMissingEntries: output.hasRecoverableMissingInspectEntries,
      shouldScheduleRecovery: shouldScheduleRecovery
    )
    reconcilePresentedAcpPermissionBatch(
      allowAutoPresentation: allowAutoPresentation || hadPresentedBatch
    )
    reconcileAcpPermissionDecisions()
  }

}
