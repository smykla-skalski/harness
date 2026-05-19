// swiftlint:disable file_length
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

  func replaceAcpInspect(
    _ response: AcpAgentInspectResponse,
    sessionID: String,
    sampledAt: Date,
    shouldScheduleRecovery: Bool = true
  ) {
    guard sessionID == selectedSessionID else {
      return
    }
    advanceAcpRuntimeStateGeneration()
    noteAcpSessionActivity(sessionID: sessionID, at: sampledAt)
    let daemonObservedAt = response.daemonPerceivedNowDate ?? sampledAt
    let nextSample = AcpInspectSample(
      sessionID: sessionID,
      sampledAt: daemonObservedAt,
      receivedAt: sampledAt,
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

  func replaceAcpInspectAsync(
    _ response: AcpAgentInspectResponse,
    sessionID: String,
    sampledAt: Date,
    shouldScheduleRecovery: Bool = true
  ) async {
    guard sessionID == selectedSessionID else {
      return
    }
    let generation = advanceAcpRuntimeStateGeneration()
    noteAcpSessionActivity(sessionID: sessionID, at: sampledAt)
    let activeAgents = selectedAcpAgents
    let currentSyncEntries = selectedAcpInspectSyncEntries
    let output = await acpRuntimeWorker.inspectReplacement(
      response: response,
      sessionID: sessionID,
      sampledAt: sampledAt,
      activeAgents: activeAgents,
      currentSyncEntries: currentSyncEntries
    )
    guard
      sessionID == selectedSessionID,
      isCurrentAcpRuntimeStateGeneration(generation),
      !Task.isCancelled
    else {
      return
    }
    selectedAcpInspectState = output.sample
    selectedAcpInspectSyncEntries = output.syncEntries
    finishAcpInspectSyncReconciliation(
      sessionID: sessionID,
      hasRecoverableMissingEntries: output.hasRecoverableMissingEntries,
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
    let liveToolCallRowIDs = Set(
      entries.lazy.compactMap { $0.toolCallTimelineEntryMetadata()?.rowID }
    )
    let visibleToolCallCount = liveToolCallRowIDs.count
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
    liveToolCallAnnouncementRowIDs = liveToolCallRowIDs
    guard !entries.isEmpty else {
      return
    }
    applyAcpTranscriptEntries(entries)
    applyAcpTimelineEntries(entries)
  }

  func applyAcpEventsFromStream(_ payload: AcpEventBatchPayload, recordedAt: String) async {
    guard payload.sessionId == selectedSessionID else {
      return
    }
    noteAcpSessionActivity(sessionID: payload.sessionId)
    let selectedSessionID = selectedSessionID
    let descriptorsByID = acpAgentDescriptorsByID
    let sessionRegistrations = selectedSession?.agents ?? []
    let snapshots = selectedAcpAgents
    let inspectSample = selectedAcpInspectState
    let output = await acpRuntimeWorker.eventPresentation(
      payload: payload,
      recordedAt: recordedAt,
      selectedSessionID: selectedSessionID,
      descriptorsByID: descriptorsByID,
      sessionRegistrations: sessionRegistrations,
      snapshots: snapshots,
      inspectSample: inspectSample
    )
    guard payload.sessionId == self.selectedSessionID, !Task.isCancelled else {
      return
    }
    toolCallTimelineOverflowNotice = output.overflowNotice
    liveToolCallAnnouncementRowIDs = output.liveToolCallRowIDs
    guard !output.entries.isEmpty else {
      return
    }
    applyAcpTranscriptEntries(output.entries)
    applyAcpTimelineEntries(output.entries)
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
    advanceAcpRuntimeStateGeneration()

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

  func applyAcpPermissionBatchFromStream(_ batch: AcpPermissionBatch) async {
    guard batch.sessionId == selectedSessionID else {
      return
    }
    noteAcpSessionActivity(sessionID: batch.sessionId)
    let decisionID = AcpPermissionDecisionPayload.decisionID(for: batch.batchId)
    if acpPermissionTerminalOutcomesByID[decisionID] != nil {
      return
    }

    let generation = advanceAcpRuntimeStateGeneration()
    let output = await acpRuntimeWorker.permissionBatchApply(
      batch: batch,
      currentAgents: selectedAcpAgents,
      standalonePermissionBatches: standaloneAcpPermissionBatches
    )
    guard
      batch.sessionId == selectedSessionID,
      isCurrentAcpRuntimeStateGeneration(generation),
      !Task.isCancelled
    else {
      return
    }
    selectedAcpAgents = output.selectedAgents
    standaloneAcpPermissionBatches = output.standalonePermissionBatches
    reconcilePresentedAcpPermissionBatch()
    reconcileAcpPermissionDecisions()
  }

  func removeAcpPermissionBatch(
    _ batch: AcpPermissionBatch,
    reason: AcpPermissionBatchRemovalReason = .resolved
  ) {
    advanceAcpRuntimeStateGeneration()
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
      cancelAcpPermissionShutdownResolutionTask(for: decisionID)
      acpPermissionPendingShutdownDecisionIDs.remove(decisionID)
      let inserted = acpPermissionPendingTimeoutDecisionIDs.insert(decisionID).inserted
      if inserted {
        scheduleAcpPermissionDeadlineResolution(for: batch, decisionID: decisionID)
      }
    } else if reason == .shutdown {
      cancelAcpPermissionDeadlineResolutionTask(for: decisionID)
      acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
      let inserted = acpPermissionPendingShutdownDecisionIDs.insert(decisionID).inserted
      if inserted {
        scheduleAcpPermissionShutdownResolution(for: batch, decisionID: decisionID)
      }
    } else {
      acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
      acpPermissionPendingShutdownDecisionIDs.remove(decisionID)
      cancelAcpPermissionTerminalResolutionTasks(for: decisionID)
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

  func removeAcpPermissionBatchFromStream(
    _ batch: AcpPermissionBatch,
    reason: AcpPermissionBatchRemovalReason = .resolved
  ) async {
    let generation = advanceAcpRuntimeStateGeneration()
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
      cancelAcpPermissionShutdownResolutionTask(for: decisionID)
      acpPermissionPendingShutdownDecisionIDs.remove(decisionID)
      let inserted = acpPermissionPendingTimeoutDecisionIDs.insert(decisionID).inserted
      if inserted {
        scheduleAcpPermissionDeadlineResolution(for: batch, decisionID: decisionID)
      }
    } else if reason == .shutdown {
      cancelAcpPermissionDeadlineResolutionTask(for: decisionID)
      acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
      let inserted = acpPermissionPendingShutdownDecisionIDs.insert(decisionID).inserted
      if inserted {
        scheduleAcpPermissionShutdownResolution(for: batch, decisionID: decisionID)
      }
    } else {
      acpPermissionPendingTimeoutDecisionIDs.remove(decisionID)
      acpPermissionPendingShutdownDecisionIDs.remove(decisionID)
      cancelAcpPermissionTerminalResolutionTasks(for: decisionID)
    }

    let output = await acpRuntimeWorker.permissionBatchRemoval(
      batch: batch,
      currentAgents: selectedAcpAgents,
      standalonePermissionBatches: standaloneAcpPermissionBatches
    )
    guard isCurrentAcpRuntimeStateGeneration(generation), !Task.isCancelled else {
      return
    }
    standaloneAcpPermissionBatches = output.standalonePermissionBatches
    selectedAcpAgents = output.selectedAgents
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
    advanceAcpRuntimeStateGeneration()
    suppressSelectedAcpTranscriptCacheWrite = true
    defer { suppressSelectedAcpTranscriptCacheWrite = false }
    selectedAcpAgents = []
    selectedAcpTranscriptSource = nil
    selectedAcpTranscriptHistoryEntries = []
    selectedAcpTranscriptLiveEntries = []
    selectedAcpTranscriptEntries = []
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
    stopAcpPermissionDecisionProcessing()
  }

  /// `agentId` keeps the visible row stable, while daemon permission batches still arrive under
  /// the transient runtime `acpId`. When the same agent restarts with a new `acpId`, drop any
  /// standalone batches from the retired runtime before rebuilding decision state so stale queue
  /// rows do not outlive the row they belonged to.
  private func staleDecisionIDsForRestartedAcpRuntime(
    replacedBy snapshot: AcpAgentSnapshot
  ) -> Set<String> {
    guard
      let previousSnapshot = selectedAcpAgents.first(where: {
        $0.sessionAgentID == snapshot.sessionAgentID
      }),
      previousSnapshot.managedAgentID != snapshot.managedAgentID
    else {
      return []
    }

    let staleBatches = standaloneAcpPermissionBatches.filter {
      $0.acpId == previousSnapshot.managedAgentID
    }
    guard !staleBatches.isEmpty else {
      return []
    }

    standaloneAcpPermissionBatches.removeAll {
      $0.acpId == previousSnapshot.managedAgentID
    }
    return Set(staleBatches.map { acpPermissionDecisionID(for: $0.batchId) })
  }
}
