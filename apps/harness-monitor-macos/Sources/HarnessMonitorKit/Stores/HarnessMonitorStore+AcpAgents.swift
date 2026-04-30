import Foundation
import SwiftData

extension HarnessMonitorStore {
  /// Pending ACP queue for the selected session.
  ///
  /// UI-0 contract: this array stays oldest-first by daemon `createdAt`, but selection/presentation
  /// is sticky to the batch the operator is already handling. Future Decisions-window rows may
  /// render the same queue differently, but they must preserve these ordering semantics.
  public var pendingAcpPermissionBatches: [AcpPermissionBatch] {
    let selectedBatches = selectedAcpAgents.flatMap(\.pendingPermissionBatches)
    return sortedAcpPermissionBatches(
      mergedPermissionBatches(
        primary: selectedBatches,
        secondary: standaloneAcpPermissionBatches,
        preferSecondary: false
      )
    )
  }

  public func fetchAcpAgentDescriptors() async -> [AcpAgentDescriptor] {
    guard let client else {
      return Array(acpAgentDescriptorsByID.values)
    }
    let descriptors =
      (try? await client.acpAgentDescriptors()) ?? Array(acpAgentDescriptorsByID.values)
    acpAgentDescriptorsByID = Dictionary(
      uniqueKeysWithValues: descriptors.map { ($0.id, $0) }
    )
    return descriptors
  }

  public func fetchRuntimeProbeResults() async -> AcpRuntimeProbeResponse? {
    guard let client else { return nil }
    return try? await client.runtimeProbeResults()
  }

  @discardableResult
  public func startAcpAgent(
    agentID: String,
    prompt: String?,
    projectDir: String? = nil,
    sessionID: String? = nil
  ) async -> AcpAgentSnapshot? {
    let actionName = "Agent started"
    let explicitSessionID = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
    let action =
      if let explicitSessionID, !explicitSessionID.isEmpty {
        prepareSessionAction(named: actionName, sessionID: explicitSessionID)
      } else {
        prepareSelectedSessionAction(named: actionName)
      }
    guard let action else { return nil }
    let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedProjectDir = projectDir?.trimmingCharacters(in: .whitespacesAndNewlines)

    do {
      let measuredSnapshot = try await Self.measureOperation {
        try await action.client.startManagedAcpAgent(
          sessionID: action.sessionID,
          request: AcpAgentStartRequest(
            agent: agentID,
            prompt: trimmedPrompt?.isEmpty == false ? trimmedPrompt : nil,
            projectDir: trimmedProjectDir?.isEmpty == false ? trimmedProjectDir : nil
          )
        )
      }
      recordRequestSuccess()
      guard case .acp(let snapshot) = measuredSnapshot.value else {
        presentFailureFeedback("Agent controller returned an unexpected response.")
        return nil
      }
      applyAcpAgent(snapshot)
      presentSuccessFeedback(actionName)
      return snapshot
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  func applyAcpAgent(_ snapshot: AcpAgentSnapshot) {
    guard snapshot.sessionId == selectedSessionID else {
      return
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
    dropAcpInspectSnapshot(acpID: snapshot.acpId, agentID: snapshot.agentId)
    reconcilePresentedAcpPermissionBatch()
    reconcileAcpPermissionDecisions()
  }

  func replaceAcpAgents(
    _ payload: AcpAgentsReconciledPayload,
    allowAutoPresentation: Bool = true
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
    reconcileAcpInspectState(
      sessionID: payload.sessionId,
      activeAgents: selectedAcpAgents
    )
    reconcilePresentedAcpPermissionBatch(
      allowAutoPresentation: allowAutoPresentation || hadPresentedBatch
    )
    reconcileAcpPermissionDecisions()
  }

  func replaceAcpInspect(
    _ response: AcpAgentInspectResponse,
    sessionID: String,
    sampledAt: Date
  ) {
    guard sessionID == selectedSessionID else {
      return
    }
    noteAcpSessionActivity(sessionID: sessionID, at: sampledAt)
    selectedAcpInspectState = AcpInspectSample(
      sessionID: sessionID,
      sampledAt: sampledAt,
      agents: sortedAcpInspectSnapshots(
        response.agents.filter { $0.sessionId == sessionID }
      )
    )
  }

  /// Apply an already-decoded ACP event push to the in-memory timeline.
  ///
  /// UI-0 contract: any future WS coalescer remains Swift-side only and sits before this method.
  /// This apply step therefore assumes stable wire payloads and mutates the store exactly once per
  /// accepted batch.
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

  /// Upsert one ACP permission batch using `batchId` as the idempotency key.
  ///
  /// UI-0 contract: same-id replays refresh the existing queue entry in place rather than creating
  /// a second pending batch. Fresh batches append according to daemon `createdAt`.
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
