import Foundation

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
    reconcilePresentedAcpPermissionBatch()
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

  func applyAcpProcessIncident(
    _ payload: AcpProcessIncidentPayload,
    recordedAt: String,
    sessionID: String?
  ) {
    guard let resolvedSessionID = sessionID ?? payload.affectedLogicalSessionIds.first,
      resolvedSessionID == selectedSessionID
    else {
      return
    }
    let entry = TimelineEntry(
      entryId: "acp-incident-\(payload.processKey)-\(recordedAt)-\(payload.kind)",
      recordedAt: recordedAt,
      kind: "acp_process_incident",
      sessionId: resolvedSessionID,
      agentId: nil,
      taskId: nil,
      summary: "ACP process incident: \(payload.kind)",
      payload: .object([
        "runtime": .string("acp"),
        "incident": .object([
          "kind": .string(payload.kind),
          "reason_kind": .string(payload.reasonKind),
          "process_key": .string(payload.processKey),
          "pid": .number(Double(payload.pid)),
          "pgid": .number(Double(payload.pgid)),
          "exit_code": payload.exitCode.map { .number(Double($0)) } ?? .null,
          "exit_signal": payload.exitSignal.map { .number(Double($0)) } ?? .null,
          "stderr_tail": payload.stderrTail.map(JSONValue.string) ?? .null,
          "affected_logical_session_ids": .array(
            payload.affectedLogicalSessionIds.map(JSONValue.string)
          ),
        ]),
      ])
    )
    applyAcpTimelineEntries([entry])
  }

  func applyAcpBridgeResyncIncident(
    _ payload: AcpBridgeResyncIncidentPayload,
    recordedAt: String,
    sessionID: String?
  ) {
    guard let resolvedSessionID = sessionID ?? payload.affectedLogicalSessionIds.first,
      resolvedSessionID == selectedSessionID
    else {
      return
    }
    let entry = TimelineEntry(
      entryId: "acp-resync-\(payload.bridgeEpoch)-\(payload.continuity)-\(payload.nextSeq)-\(resolvedSessionID)",
      recordedAt: recordedAt,
      kind: "acp_bridge_resync_incident",
      sessionId: resolvedSessionID,
      agentId: nil,
      taskId: nil,
      summary: "ACP bridge resync incident: \(payload.kind)",
      payload: .object([
        "runtime": .string("acp"),
        "incident": .object([
          "kind": .string(payload.kind),
          "bridge_epoch": .string(payload.bridgeEpoch),
          "continuity": .number(Double(payload.continuity)),
          "next_seq": .number(Double(payload.nextSeq)),
          "truncated": .bool(payload.truncated),
          "affected_logical_session_ids": .array(
            payload.affectedLogicalSessionIds.map(JSONValue.string)
          ),
        ]),
      ])
    )
    applyAcpTimelineEntries([entry])
  }

  /// Upsert one ACP permission batch using `batchId` as the idempotency key.
  ///
  /// UI-0 contract: same-id replays refresh the existing queue entry in place rather than creating
  /// a second pending batch. Fresh batches append according to daemon `createdAt`.
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

  /// Preserve the currently presented batch whenever that batch is still pending and actively
  /// resolving; otherwise advance to the oldest remaining batch.
  ///
  /// UI-0 sticky-selection contract: new arrivals do not steal focus from the in-flight batch.
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

  /// Canonical queue ordering for ACP batches.
  ///
  /// UI-0 contract: oldest daemon-created batch wins; `batchId` is only the stable tiebreaker.
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

  private func applyAcpTimelineEntries(_ entries: [TimelineEntry]) {
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
