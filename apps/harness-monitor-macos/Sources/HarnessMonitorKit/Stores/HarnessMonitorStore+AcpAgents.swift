import Foundation

extension HarnessMonitorStore {
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
    guard let client else { return [] }
    return (try? await client.acpAgentDescriptors()) ?? []
  }

  public func fetchRuntimeProbeResults() async -> AcpRuntimeProbeResponse? {
    guard let client else { return nil }
    return try? await client.runtimeProbeResults()
  }

  @discardableResult
  public func startAcpAgent(
    agentID: String,
    prompt: String?,
    projectDir: String? = nil
  ) async -> AcpAgentSnapshot? {
    let actionName = "Agent started"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return nil }
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

  @discardableResult
  public func resolveAcpPermission(
    batch: AcpPermissionBatch,
    decision: AcpPermissionDecision
  ) async -> Bool {
    let actionName = "Permission resolved"
    guard let action = prepareSelectedSessionAction(named: actionName) else { return false }
    resolvingAcpPermissionBatchID = batch.batchId
    defer { resolvingAcpPermissionBatchID = nil }
    do {
      let measuredSnapshot = try await Self.measureOperation {
        try await action.client.resolveManagedAcpPermission(
          agentID: batch.acpId,
          batchID: batch.batchId,
          decision: decision
        )
      }
      recordRequestSuccess()
      if case .acp(let snapshot) = measuredSnapshot.value {
        applyAcpAgent(snapshot)
      }
      if presentingAcpPermissionBatch?.batchId == batch.batchId {
        presentingAcpPermissionBatch = nil
      }
      presentSuccessFeedback(actionName)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  func applyAcpAgent(_ snapshot: AcpAgentSnapshot) {
    guard snapshot.sessionId == selectedSessionID else {
      return
    }

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
    reconcilePresentedAcpPermissionBatch()
  }

  func replaceAcpAgents(_ payload: AcpAgentsReconciledPayload) {
    guard payload.sessionId == selectedSessionID else {
      return
    }
    selectedAcpAgents = sortedAcpAgents(payload.agents.map { snapshot in
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
    })
    standaloneAcpPermissionBatches.removeAll { $0.sessionId == payload.sessionId }
    reconcilePresentedAcpPermissionBatch()
  }

  func applyAcpEvents(_ payload: AcpEventBatchPayload, recordedAt: String) {
    guard payload.sessionId == selectedSessionID else {
      return
    }
    let entries = payload.timelineEntries(fallbackRecordedAt: recordedAt)
    guard !entries.isEmpty else {
      return
    }

    let mergedTimeline = mergedTimelineEntries(timeline, with: entries)
    guard mergedTimeline != timeline else {
      return
    }
    timeline = mergedTimeline
    timelineWindow = normalizedTimelineWindow(timelineWindow, loadedTimeline: mergedTimeline)

    guard let selectedSession else {
      return
    }
    scheduleCacheWrite { service in
      await service.cacheSessionDetail(
        selectedSession,
        timeline: mergedTimeline,
        timelineWindow: TimelineWindowResponse.fallbackMetadata(for: mergedTimeline)
      )
    }
  }

  func applyAcpPermissionBatch(_ batch: AcpPermissionBatch) {
    guard batch.sessionId == selectedSessionID else {
      return
    }

    if !selectedAcpAgents.contains(where: { $0.acpId == batch.acpId }) {
      standaloneAcpPermissionBatches = upsertingAcpPermissionBatch(
        batch,
        into: standaloneAcpPermissionBatches
      )
      reconcilePresentedAcpPermissionBatch()
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
  }

  func removeAcpPermissionBatch(_ batch: AcpPermissionBatch) {
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
  }

  func resetSelectedAcpAgents() {
    selectedAcpAgents = []
    standaloneAcpPermissionBatches = []
    presentingAcpPermissionBatch = nil
    resolvingAcpPermissionBatchID = nil
  }

  func reconcilePresentedAcpPermissionBatch() {
    let batches = pendingAcpPermissionBatches
    guard !batches.isEmpty else {
      presentingAcpPermissionBatch = nil
      return
    }
    if let current = presentingAcpPermissionBatch,
      resolvingAcpPermissionBatchID == current.batchId,
      batches.contains(where: { $0.batchId == current.batchId })
    {
      return
    }
    presentingAcpPermissionBatch = batches[0]
  }

  private func upsertingAcpAgent(
    _ snapshot: AcpAgentSnapshot,
    into snapshots: [AcpAgentSnapshot]
  ) -> [AcpAgentSnapshot] {
    var updated = snapshots.filter { $0.acpId != snapshot.acpId }
    updated.append(snapshot)
    return sortedAcpAgents(updated)
  }

  private func sortedAcpAgents(_ snapshots: [AcpAgentSnapshot]) -> [AcpAgentSnapshot] {
    snapshots.sorted {
      if $0.displayName != $1.displayName {
        return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
      return $0.acpId < $1.acpId
    }
  }

  private func mergedPermissionBatches(
    primary: [AcpPermissionBatch],
    secondary: [AcpPermissionBatch],
    preferSecondary: Bool = true
  ) -> [AcpPermissionBatch] {
    var byBatchID: [String: AcpPermissionBatch] = [:]
    for batch in primary {
      byBatchID[batch.batchId] = batch
    }
    for batch in secondary {
      if shouldReplacePermissionBatch(
        existing: byBatchID[batch.batchId],
        incoming: batch,
        preferSecondary: preferSecondary
      ) {
        byBatchID[batch.batchId] = batch
      }
    }
    return Array(byBatchID.values)
  }

  private func shouldReplacePermissionBatch(
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
    // Keep selected snapshot authoritative against stale replay, but allow
    // equal/newer same-id refreshes to replace older payloads.
    return incoming.createdAt >= existing.createdAt
  }

  private func upsertingAcpPermissionBatch(
    _ batch: AcpPermissionBatch,
    into batches: [AcpPermissionBatch]
  ) -> [AcpPermissionBatch] {
    sortedAcpPermissionBatches(batches.filter { $0.batchId != batch.batchId } + [batch])
  }

  private func sortedAcpPermissionBatches(
    _ batches: [AcpPermissionBatch]
  ) -> [AcpPermissionBatch] {
    batches.sorted {
      if $0.createdAt != $1.createdAt {
        return $0.createdAt < $1.createdAt
      }
      return $0.batchId < $1.batchId
    }
  }

  private func mergedTimelineEntries(
    _ current: [TimelineEntry],
    with incoming: [TimelineEntry]
  ) -> [TimelineEntry] {
    Dictionary(grouping: current + incoming, by: \.entryId)
      .compactMap { _, entries in entries.last }
      .sorted {
        if $0.recordedAt != $1.recordedAt {
          return $0.recordedAt > $1.recordedAt
        }
        return $0.entryId < $1.entryId
      }
  }
}

extension AcpAgentSnapshot {
  fileprivate func withPermissionBatches(_ batches: [AcpPermissionBatch]) -> AcpAgentSnapshot {
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
