import Foundation

extension HarnessMonitorStore {
  func upsertingAcpAgent(
    _ snapshot: AcpAgentSnapshot,
    into snapshots: [AcpAgentSnapshot]
  ) -> [AcpAgentSnapshot] {
    var result = snapshots.filter { $0.sessionAgentID != snapshot.sessionAgentID }
    let idx =
      result.firstIndex { existing in acpAgentPrecedes(snapshot, existing) } ?? result.endIndex
    result.insert(snapshot, at: idx)
    return result
  }

  func sortedAcpAgents(_ snapshots: [AcpAgentSnapshot]) -> [AcpAgentSnapshot] {
    snapshots.sorted { acpAgentPrecedes($0, $1) }
  }

  private func acpAgentPrecedes(
    _ lhs: AcpAgentSnapshot, _ rhs: AcpAgentSnapshot
  ) -> Bool {
    if lhs.displayName != rhs.displayName {
      return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
    return lhs.sessionAgentID < rhs.sessionAgentID
  }

  func sortedAcpInspectSnapshots(
    _ snapshots: [AcpAgentInspectSnapshot]
  ) -> [AcpAgentInspectSnapshot] {
    snapshots.sorted {
      if $0.displayName != $1.displayName {
        return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
      return $0.acpId < $1.acpId
    }
  }

  func mergedPermissionBatches(
    primary: [AcpPermissionBatch],
    secondary: [AcpPermissionBatch],
    preferSecondary: Bool = true
  ) -> [AcpPermissionBatch] {
    var byBatchID: [String: AcpPermissionBatch] = [:]
    for batch in primary {
      byBatchID[batch.batchId] = batch
    }
    for batch in secondary
    where shouldReplacePermissionBatch(
      existing: byBatchID[batch.batchId],
      incoming: batch,
      preferSecondary: preferSecondary
    ) {
      byBatchID[batch.batchId] = batch
    }
    return Array(byBatchID.values)
  }

  func shouldReplacePermissionBatch(
    existing: AcpPermissionBatch?,
    incoming: AcpPermissionBatch,
    preferSecondary: Bool
  ) -> Bool {
    guard let existing else {
      return true
    }
    if preferSecondary {
      return true
    }
    return incoming.createdAt >= existing.createdAt
  }

  func upsertingAcpPermissionBatch(
    _ batch: AcpPermissionBatch,
    into batches: [AcpPermissionBatch]
  ) -> [AcpPermissionBatch] {
    var result = batches.filter { $0.batchId != batch.batchId }
    let idx =
      result.firstIndex { existing in acpPermissionBatchPrecedes(batch, existing) }
      ?? result.endIndex
    result.insert(batch, at: idx)
    return result
  }

  private func acpPermissionBatchPrecedes(
    _ lhs: AcpPermissionBatch, _ rhs: AcpPermissionBatch
  ) -> Bool {
    if lhs.createdAt != rhs.createdAt {
      return lhs.createdAt < rhs.createdAt
    }
    return lhs.batchId < rhs.batchId
  }

  /// Canonical queue ordering for ACP batches.
  ///
  /// UI-0 contract: oldest daemon-created batch wins; `batchId` is only the stable tiebreaker.
  func sortedAcpPermissionBatches(
    _ batches: [AcpPermissionBatch]
  ) -> [AcpPermissionBatch] {
    batches.sorted {
      if $0.createdAt != $1.createdAt {
        return $0.createdAt < $1.createdAt
      }
      return $0.batchId < $1.batchId
    }
  }

  func reconcileAcpInspectSnapshot(with snapshot: AcpAgentSnapshot) {
    guard let selectedAcpInspectState else {
      return
    }
    let incomingIdentity = AcpRuntimeIdentity(snapshot: snapshot)
    guard selectedAcpInspectState.snapshot(for: incomingIdentity) == nil else {
      return
    }
    self.selectedAcpInspectState = selectedAcpInspectState.filtered(
      removingMatching: { identity in
        identity != incomingIdentity
          && (identity.managedAgentID == snapshot.managedAgentID
            || identity.sessionAgentID == snapshot.sessionAgentID)
      }
    )
  }

  func reconcileAcpInspectState(
    sessionID: String,
    activeAgents: [AcpAgentSnapshot]
  ) {
    guard let selectedAcpInspectState, selectedAcpInspectState.sessionID == sessionID else {
      return
    }
    let activeIdentities = Set(activeAgents.map(AcpRuntimeIdentity.init(snapshot:)))
    self.selectedAcpInspectState = selectedAcpInspectState.filtered(
      keeping: activeIdentities
    )
  }
}

extension AcpAgentSnapshot {
  func withPermissionBatches(_ batches: [AcpPermissionBatch]) -> AcpAgentSnapshot {
    var batchesByID: [String: AcpPermissionBatch] = [:]
    for batch in batches {
      batchesByID[batch.batchId] = batch
    }
    let sortedBatches = batchesByID.values.sorted {
      if $0.createdAt != $1.createdAt {
        return $0.createdAt < $1.createdAt
      }
      return $0.batchId < $1.batchId
    }

    return AcpAgentSnapshot(
      acpId: acpId,
      sessionId: sessionId,
      agentId: agentId,
      displayName: displayName,
      status: status,
      pid: pid,
      pgid: pgid,
      projectDir: projectDir,
      pendingPermissions: sortedBatches.reduce(0) { $0 + $1.requests.count },
      permissionQueueDepth: permissionQueueDepth,
      pendingPermissionBatches: sortedBatches,
      terminalCount: terminalCount,
      createdAt: createdAt,
      updatedAt: updatedAt,
      disconnectReason: disconnectReason,
      stderrTail: stderrTail
    )
  }
}

struct AcpPermissionDecisionSyncPayloadState: Sendable {
  let sortedPayloads: [AcpPermissionDecisionPayload]
  let activeDecisionIDs: Set<String>
}

struct AcpEventPresentationOutput: Sendable {
  let entries: [TimelineEntry]
  let liveToolCallRowIDs: Set<String>
  let overflowNotice: HarnessMonitorStore.ToolCallTimelineOverflowNotice?
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

  func eventPresentation(
    payload: AcpEventBatchPayload,
    recordedAt: String,
    selectedSessionID: String?,
    descriptorsByID: [String: AcpAgentDescriptor],
    sessionRegistrations: [AgentRegistration],
    snapshots: [AcpAgentSnapshot],
    inspectSample: AcpInspectSample?
  ) -> AcpEventPresentationOutput {
    let crosswalk = AcpAgentIdentityCrosswalk(
      selectedSessionIdentity: selectedSessionID.map(HarnessSessionID.init(rawValue:)),
      descriptorsByID: descriptorsByID,
      sessionRegistrations: sessionRegistrations,
      snapshots: snapshots,
      inspectSample: inspectSample
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

  func inspectReplacement(
    response: AcpAgentInspectResponse,
    sessionID: String,
    sampledAt: Date,
    activeAgents: [AcpAgentSnapshot],
    currentSyncEntries: [AcpRuntimeIdentity: AcpInspectSyncEntry]
  ) -> AcpInspectReplacementOutput {
    let daemonObservedAt = response.daemonPerceivedNowDate ?? sampledAt
    let inspectSnapshots = Self.sortedInspectSnapshots(
      response.agents.filter { $0.sessionId == sessionID }
    )
    let sample = AcpInspectSample(
      sessionID: sessionID,
      sampledAt: daemonObservedAt,
      receivedAt: sampledAt,
      agents: inspectSnapshots
    )
    let syncEntries = Self.reconciledInspectSyncEntries(
      activeAgents: activeAgents,
      inspectedAgents: inspectSnapshots,
      currentEntries: currentSyncEntries,
      response: response,
      sampledAt: sampledAt
    )
    return AcpInspectReplacementOutput(
      sample: sample,
      syncEntries: syncEntries,
      hasRecoverableMissingEntries: syncEntries.values.contains { $0.phase != .unavailable }
    )
  }

  func permissionDecisionSyncPayloadState(
    _ payloads: [AcpPermissionDecisionPayload]
  ) -> AcpPermissionDecisionSyncPayloadState {
    let sortedPayloads = payloads.sorted {
      if $0.rawBatch.createdAt != $1.rawBatch.createdAt {
        return $0.rawBatch.createdAt < $1.rawBatch.createdAt
      }
      return $0.decisionID < $1.decisionID
    }
    return AcpPermissionDecisionSyncPayloadState(
      sortedPayloads: sortedPayloads,
      activeDecisionIDs: Set(sortedPayloads.map(\.decisionID))
    )
  }

  func sortedPermissionDecisionPayloads(
    _ payloads: [AcpPermissionDecisionPayload]
  ) -> [AcpPermissionDecisionPayload] {
    permissionDecisionSyncPayloadState(payloads).sortedPayloads
  }

  func stalePermissionDecisionIDs(
    openDecisionIDs: Set<String>,
    activeDecisionIDs: Set<String>,
    staleDecisionIDs: Set<String>,
    protectedDecisionIDs: Set<String>,
    pendingTimeoutDecisionIDs: Set<String>,
    pendingShutdownDecisionIDs: Set<String>,
    terminalDecisionIDs: Set<String>
  ) -> [String] {
    openDecisionIDs
      .subtracting(activeDecisionIDs)
      .union(staleDecisionIDs)
      .subtracting(protectedDecisionIDs)
      .subtracting(pendingTimeoutDecisionIDs)
      .subtracting(pendingShutdownDecisionIDs)
      .subtracting(terminalDecisionIDs)
      .sorted()
  }

  func markInspectEntriesRetrying(
    entries: [AcpRuntimeIdentity: AcpInspectSyncEntry],
    attemptedAt: Date
  ) -> [AcpRuntimeIdentity: AcpInspectSyncEntry] {
    var nextEntries = entries
    for identity in nextEntries.keys.sorted(by: { $0.id < $1.id }) {
      guard var entry = nextEntries[identity], entry.phase != .unavailable else {
        continue
      }
      entry.phase = .retrying
      entry.lastAttemptAt = attemptedAt
      entry.retryCount += 1
      entry.message = nil
      nextEntries[identity] = entry
    }
    return nextEntries
  }

  func promoteInspectEntriesToStalled(
    entries: [AcpRuntimeIdentity: AcpInspectSyncEntry],
    phases: Set<AcpRuntimeInspectPhase>
  ) -> [AcpRuntimeIdentity: AcpInspectSyncEntry] {
    var nextEntries = entries
    for identity in nextEntries.keys.sorted(by: { $0.id < $1.id }) {
      guard var entry = nextEntries[identity], phases.contains(entry.phase) else {
        continue
      }
      entry.phase = .stalled
      entry.message = nil
      nextEntries[identity] = entry
    }
    return nextEntries
  }

  func waitForIdle() async {}

  private static func toolCallTimelineMetadata(
    for payload: AcpEventBatchPayload,
    crosswalk: AcpAgentIdentityCrosswalk
  ) -> AcpToolCallTimelineMetadata {
    let linkage = crosswalk.agentLinkage(
      forManagedAgentIdentity: payload.managedAgentIdentity
    )
    let fallbackSessionAgentIdentity = payload.events.lazy.compactMap(\.sessionAgentIdentity).first
    let fallbackSessionAgentID =
      fallbackSessionAgentIdentity?.rawValue
      ?? linkage?.explicitSessionAgentLookupKey
      ?? AcpAgentIdentityCrosswalk.explicitSessionAgentFallbackKey(
        for: payload.managedAgentIdentity
      )
    return AcpToolCallTimelineMetadata(
      managedAgentID: linkage?.managedAgentIdentity.rawValue
        ?? payload.managedAgentIdentity.rawValue,
      sessionAgentID: linkage?.sessionAgentIdentity?.rawValue ?? fallbackSessionAgentID,
      displayName: linkage?.explicitDisplayName
        ?? fallbackSessionAgentIdentity?.rawValue
        ?? AcpAgentIdentityCrosswalk.unresolvedDisplayName(for: payload.managedAgentIdentity),
      capabilityTags: linkage?.capabilityTags ?? []
    )
  }

  private static func sortedInspectSnapshots(
    _ snapshots: [AcpAgentInspectSnapshot]
  ) -> [AcpAgentInspectSnapshot] {
    snapshots.sorted {
      if $0.displayName != $1.displayName {
        return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
      return $0.acpId < $1.acpId
    }
  }

  private static func sortedAgents(_ snapshots: [AcpAgentSnapshot]) -> [AcpAgentSnapshot] {
    snapshots.sorted(by: agentPrecedes)
  }

  private static func upsertingAgent(
    _ snapshot: AcpAgentSnapshot,
    into snapshots: [AcpAgentSnapshot]
  ) -> [AcpAgentSnapshot] {
    var result = snapshots.filter { $0.sessionAgentID != snapshot.sessionAgentID }
    let index = result.firstIndex { existing in agentPrecedes(snapshot, existing) }
      ?? result.endIndex
    result.insert(snapshot, at: index)
    return result
  }

  private static func agentPrecedes(
    _ lhs: AcpAgentSnapshot,
    _ rhs: AcpAgentSnapshot
  ) -> Bool {
    if lhs.displayName != rhs.displayName {
      return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
    return lhs.sessionAgentID < rhs.sessionAgentID
  }

  private static func mergedPermissionBatches(
    primary: [AcpPermissionBatch],
    secondary: [AcpPermissionBatch],
    preferSecondary: Bool
  ) -> [AcpPermissionBatch] {
    var byBatchID: [String: AcpPermissionBatch] = [:]
    for batch in primary {
      byBatchID[batch.batchId] = batch
    }
    for batch in secondary
    where shouldReplacePermissionBatch(
      existing: byBatchID[batch.batchId],
      incoming: batch,
      preferSecondary: preferSecondary
    ) {
      byBatchID[batch.batchId] = batch
    }
    return Array(byBatchID.values)
  }

  private static func shouldReplacePermissionBatch(
    existing: AcpPermissionBatch?,
    incoming: AcpPermissionBatch,
    preferSecondary: Bool
  ) -> Bool {
    guard let existing else {
      return true
    }
    if preferSecondary {
      return true
    }
    return incoming.createdAt >= existing.createdAt
  }

  private static func upsertingPermissionBatch(
    _ batch: AcpPermissionBatch,
    into batches: [AcpPermissionBatch]
  ) -> [AcpPermissionBatch] {
    var result = batches.filter { $0.batchId != batch.batchId }
    let index = result.firstIndex { existing in permissionBatchPrecedes(batch, existing) }
      ?? result.endIndex
    result.insert(batch, at: index)
    return result
  }

  private static func permissionBatchPrecedes(
    _ lhs: AcpPermissionBatch,
    _ rhs: AcpPermissionBatch
  ) -> Bool {
    if lhs.createdAt != rhs.createdAt {
      return lhs.createdAt < rhs.createdAt
    }
    return lhs.batchId < rhs.batchId
  }

  private static func staleDecisionIDsForRestartedRuntime(
    replacedBy snapshot: AcpAgentSnapshot,
    currentAgents: [AcpAgentSnapshot],
    standalonePermissionBatches: inout [AcpPermissionBatch]
  ) -> Set<String> {
    guard
      let previousSnapshot = currentAgents.first(where: {
        $0.sessionAgentID == snapshot.sessionAgentID
      }),
      previousSnapshot.managedAgentID != snapshot.managedAgentID
    else {
      return []
    }

    let staleBatches = standalonePermissionBatches.filter {
      $0.acpId == previousSnapshot.managedAgentID
    }
    guard !staleBatches.isEmpty else {
      return []
    }

    standalonePermissionBatches.removeAll {
      $0.acpId == previousSnapshot.managedAgentID
    }
    return Set(staleBatches.map { AcpPermissionDecisionPayload.decisionID(for: $0.batchId) })
  }

  private static func reconciledInspectSample(
    _ sample: AcpInspectSample?,
    with snapshot: AcpAgentSnapshot
  ) -> AcpInspectSample? {
    guard let sample else {
      return nil
    }
    let incomingIdentity = AcpRuntimeIdentity(snapshot: snapshot)
    guard sample.snapshot(for: incomingIdentity) == nil else {
      return sample
    }
    return sample.filtered(removingMatching: { identity in
      identity != incomingIdentity
        && (identity.managedAgentID == snapshot.managedAgentID
          || identity.sessionAgentID == snapshot.sessionAgentID)
    })
  }

  private static func hasRecoverableMissingInspectEntries(
    _ entries: [AcpRuntimeIdentity: AcpInspectSyncEntry]
  ) -> Bool {
    entries.values.contains { $0.phase != .unavailable }
  }

  private static func reconciledInspectSyncEntries(
    activeAgents: [AcpAgentSnapshot],
    inspectedAgents: [AcpAgentInspectSnapshot],
    currentEntries: [AcpRuntimeIdentity: AcpInspectSyncEntry],
    response: AcpAgentInspectResponse?,
    sampledAt: Date
  ) -> [AcpRuntimeIdentity: AcpInspectSyncEntry] {
    let activeIdentities = Set(activeAgents.map(AcpRuntimeIdentity.init(snapshot:)))
    let inspectedIdentities = Set(inspectedAgents.map(AcpRuntimeIdentity.init(inspect:)))
    var nextEntries = currentEntries.filter { activeIdentities.contains($0.key) }

    for identity in inspectedIdentities {
      nextEntries.removeValue(forKey: identity)
    }

    for identity in activeIdentities.subtracting(inspectedIdentities) {
      var entry =
        nextEntries[identity]
        ?? AcpInspectSyncEntry(
          identity: identity,
          missingSince: sampledAt,
          phase: .waiting,
          lastAttemptAt: nil,
          retryCount: 0,
          message: nil
        )
      if let response {
        if response.available == false {
          entry.phase = .unavailable
          entry.message = response.issueMessage
        } else if entry.phase == .unavailable {
          entry.phase = entry.lastAttemptAt == nil ? .waiting : .stalled
          entry.message = nil
        }
      }
      nextEntries[identity] = entry
    }

    return nextEntries
  }
}
