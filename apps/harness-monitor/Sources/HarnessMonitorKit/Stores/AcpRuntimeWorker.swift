import Foundation

struct AcpPermissionDecisionSyncPayloadState: Sendable {
  let sortedPayloads: [AcpPermissionDecisionPayload]
  let activeDecisionIDs: Set<String>
}

struct AcpEventPresentationOutput: Sendable {
  let entries: [TimelineEntry]
  let liveToolCallRowIDs: Set<String>
  let overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice?
}

struct AcpEventPresentationInput: Sendable {
  let payload: AcpEventBatchPayload
  let recordedAt: String
  let selectedSessionID: String?
  let descriptorsByID: [String: AcpAgentDescriptor]
  let sessionRegistrations: [AgentRegistration]
  let snapshots: [AcpAgentSnapshot]
  let inspectSample: AcpInspectSample?
}

struct AcpPermissionDecisionStalenessInput: Sendable {
  let openDecisionIDs: Set<String>
  let activeDecisionIDs: Set<String>
  let staleDecisionIDs: Set<String>
  let protectedDecisionIDs: Set<String>
  let pendingTimeoutDecisionIDs: Set<String>
  let pendingShutdownDecisionIDs: Set<String>
  let terminalDecisionIDs: Set<String>
}

struct AcpInspectReplacementOutput: Sendable {
  let sample: AcpInspectSample
  let syncEntries: [AcpRuntimeIdentity: AcpInspectSyncEntry]
  let hasRecoverableMissingEntries: Bool
}

struct AcpAgentStateMutationOutput: Sendable {
  let selectedAgents: [AcpAgentSnapshot]
  let standalonePermissionBatches: [AcpPermissionBatch]
  let inspectSample: AcpInspectSample?
  let inspectSyncEntries: [AcpRuntimeIdentity: AcpInspectSyncEntry]
  let hasRecoverableMissingInspectEntries: Bool
  let staleRestartDecisionIDs: Set<String>
}

struct AcpPermissionBatchStateOutput: Sendable {
  let selectedAgents: [AcpAgentSnapshot]
  let standalonePermissionBatches: [AcpPermissionBatch]
}

actor AcpRuntimeWorker {
  func agentUpdate(
    snapshot: AcpAgentSnapshot,
    currentAgents: [AcpAgentSnapshot],
    standalonePermissionBatches: [AcpPermissionBatch],
    currentInspectSample: AcpInspectSample?,
    currentInspectSyncEntries: [AcpRuntimeIdentity: AcpInspectSyncEntry]
  ) -> AcpAgentStateMutationOutput {
    var standaloneBatches = standalonePermissionBatches
    let staleDecisionIDs = Self.staleDecisionIDsForRestartedRuntime(
      replacedBy: snapshot,
      currentAgents: currentAgents,
      standalonePermissionBatches: &standaloneBatches
    )

    let pendingStandaloneBatches = standaloneBatches.filter { $0.acpId == snapshot.acpId }
    standaloneBatches.removeAll { $0.acpId == snapshot.acpId }
    let updatedSnapshot = snapshot.withPermissionBatches(
      Self.mergedPermissionBatches(
        primary: snapshot.pendingPermissionBatches,
        secondary: pendingStandaloneBatches,
        preferSecondary: false
      )
    )
    let selectedAgents = Self.upsertingAgent(updatedSnapshot, into: currentAgents)
    let inspectSample = Self.reconciledInspectSample(currentInspectSample, with: snapshot)
    let syncEntries = Self.reconciledInspectSyncEntries(
      activeAgents: selectedAgents,
      inspectedAgents: inspectSample?.agents ?? [],
      currentEntries: currentInspectSyncEntries,
      response: nil,
      sampledAt: Date()
    )

    return AcpAgentStateMutationOutput(
      selectedAgents: selectedAgents,
      standalonePermissionBatches: standaloneBatches,
      inspectSample: inspectSample,
      inspectSyncEntries: syncEntries,
      hasRecoverableMissingInspectEntries: Self.hasRecoverableMissingInspectEntries(syncEntries),
      staleRestartDecisionIDs: staleDecisionIDs
    )
  }

  func agentsReplacement(
    payload: AcpAgentsReconciledPayload,
    sampledAt: Date,
    standalonePermissionBatches: [AcpPermissionBatch],
    currentInspectSample: AcpInspectSample?,
    currentInspectSyncEntries: [AcpRuntimeIdentity: AcpInspectSyncEntry]
  ) -> AcpAgentStateMutationOutput {
    var standaloneBatches = standalonePermissionBatches
    let selectedAgents = Self.sortedAgents(
      payload.agents.map { snapshot in
        let pendingStandaloneBatches = standaloneBatches.filter {
          $0.acpId == snapshot.acpId
        }
        return snapshot.withPermissionBatches(
          Self.mergedPermissionBatches(
            primary: snapshot.pendingPermissionBatches,
            secondary: pendingStandaloneBatches,
            preferSecondary: false
          )
        )
      }
    )
    standaloneBatches.removeAll { $0.sessionId == payload.sessionId }

    let activeIdentities = Set(selectedAgents.map(AcpRuntimeIdentity.init(snapshot:)))
    let inspectSample: AcpInspectSample?
    if let response = payload.inspect {
      let daemonObservedAt = response.daemonPerceivedNowDate ?? sampledAt
      inspectSample = AcpInspectSample(
        sessionID: payload.sessionId,
        sampledAt: daemonObservedAt,
        receivedAt: sampledAt,
        agents: Self.sortedInspectSnapshots(
          response.agents.filter { $0.sessionId == payload.sessionId }
        )
      )
      .filtered(keeping: activeIdentities)
    } else if let currentInspectSample, currentInspectSample.sessionID == payload.sessionId {
      inspectSample = currentInspectSample.filtered(keeping: activeIdentities)
    } else {
      inspectSample = currentInspectSample
    }

    let syncEntries = Self.reconciledInspectSyncEntries(
      activeAgents: selectedAgents,
      inspectedAgents: inspectSample?.agents ?? [],
      currentEntries: currentInspectSyncEntries,
      response: payload.inspect,
      sampledAt: sampledAt
    )

    return AcpAgentStateMutationOutput(
      selectedAgents: selectedAgents,
      standalonePermissionBatches: standaloneBatches,
      inspectSample: inspectSample,
      inspectSyncEntries: syncEntries,
      hasRecoverableMissingInspectEntries: Self.hasRecoverableMissingInspectEntries(syncEntries),
      staleRestartDecisionIDs: []
    )
  }

  func permissionBatchApply(
    batch: AcpPermissionBatch,
    currentAgents: [AcpAgentSnapshot],
    standalonePermissionBatches: [AcpPermissionBatch]
  ) -> AcpPermissionBatchStateOutput {
    guard currentAgents.contains(where: { $0.acpId == batch.acpId }) else {
      return AcpPermissionBatchStateOutput(
        selectedAgents: currentAgents,
        standalonePermissionBatches: Self.upsertingPermissionBatch(
          batch,
          into: standalonePermissionBatches
        )
      )
    }
    return AcpPermissionBatchStateOutput(
      selectedAgents: currentAgents.map { snapshot in
        guard snapshot.acpId == batch.acpId else { return snapshot }
        return snapshot.withPermissionBatches(
          Self.mergedPermissionBatches(
            primary: snapshot.pendingPermissionBatches,
            secondary: [batch],
            preferSecondary: false
          )
        )
      },
      standalonePermissionBatches: standalonePermissionBatches
    )
  }

  func permissionBatchRemoval(
    batch: AcpPermissionBatch,
    currentAgents: [AcpAgentSnapshot],
    standalonePermissionBatches: [AcpPermissionBatch]
  ) -> AcpPermissionBatchStateOutput {
    AcpPermissionBatchStateOutput(
      selectedAgents: currentAgents.map { snapshot in
        guard snapshot.acpId == batch.acpId else { return snapshot }
        let batches = snapshot.pendingPermissionBatches.filter { $0.batchId != batch.batchId }
        return snapshot.withPermissionBatches(batches)
      },
      standalonePermissionBatches: standalonePermissionBatches.filter {
        $0.batchId != batch.batchId
      }
    )
  }

  func eventPresentation(input: AcpEventPresentationInput) -> AcpEventPresentationOutput {
    let payload = input.payload
    let recordedAt = input.recordedAt
    let crosswalk = AcpAgentIdentityCrosswalk(
      selectedSessionIdentity: input.selectedSessionID.map(HarnessSessionID.init(rawValue:)),
      descriptorsByID: input.descriptorsByID,
      sessionRegistrations: input.sessionRegistrations,
      snapshots: input.snapshots,
      inspectSample: input.inspectSample
    )
    let metadata = Self.toolCallTimelineMetadata(for: payload, crosswalk: crosswalk)
    let entries = payload.timelineEntries(
      fallbackRecordedAt: recordedAt,
      toolCallMetadata: metadata
    )
    let liveToolCallRowIDs = Set(
      entries.lazy.compactMap { $0.toolCallTimelineEntryMetadata()?.rowID }
    )
    let overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice?
    if payload.rawCount > payload.events.count {
      overflowNotice = HarnessMonitorStore.ToolCallTimelineOverflowNotice(
        sessionID: payload.sessionId,
        rawUpdateCount: payload.rawCount,
        displayedEventCount: liveToolCallRowIDs.count,
        recordedAt: recordedAt
      )
    } else {
      overflowNotice = nil
    }
    return AcpEventPresentationOutput(
      entries: entries,
      liveToolCallRowIDs: liveToolCallRowIDs,
      overflowNotice: overflowNotice
    )
  }
}
