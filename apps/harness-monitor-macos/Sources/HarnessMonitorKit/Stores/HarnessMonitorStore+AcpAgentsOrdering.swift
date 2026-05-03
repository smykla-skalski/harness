import Foundation

extension HarnessMonitorStore {
  func upsertingAcpAgent(
    _ snapshot: AcpAgentSnapshot,
    into snapshots: [AcpAgentSnapshot]
  ) -> [AcpAgentSnapshot] {
    var result = snapshots.filter { $0.acpId != snapshot.acpId }
    let idx =
      result.firstIndex { existing in
        if snapshot.displayName != existing.displayName {
          return snapshot.displayName.localizedStandardCompare(existing.displayName)
            == .orderedAscending
        }
        return snapshot.acpId < existing.acpId
      } ?? result.endIndex
    result.insert(snapshot, at: idx)
    return result
  }

  func sortedAcpAgents(_ snapshots: [AcpAgentSnapshot]) -> [AcpAgentSnapshot] {
    snapshots.sorted {
      if $0.displayName != $1.displayName {
        return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
      return $0.acpId < $1.acpId
    }
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
    sortedAcpPermissionBatches(batches.filter { $0.batchId != batch.batchId } + [batch])
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
          && (identity.acpID == snapshot.acpId || identity.agentID == snapshot.agentId)
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
