import Foundation

extension AcpRuntimeWorker {
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

  func stalePermissionDecisionIDs(input: AcpPermissionDecisionStalenessInput) -> [String] {
    input.openDecisionIDs
      .subtracting(input.activeDecisionIDs)
      .union(input.staleDecisionIDs)
      .subtracting(input.protectedDecisionIDs)
      .subtracting(input.pendingTimeoutDecisionIDs)
      .subtracting(input.pendingShutdownDecisionIDs)
      .subtracting(input.terminalDecisionIDs)
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
    let index =
      result.firstIndex { existing in agentPrecedes(snapshot, existing) }
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
    let index =
      result.firstIndex { existing in permissionBatchPrecedes(batch, existing) }
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
