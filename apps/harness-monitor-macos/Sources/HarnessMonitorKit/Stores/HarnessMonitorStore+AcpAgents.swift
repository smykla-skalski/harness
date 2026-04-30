import Foundation
import SwiftData

private enum AcpAgentSnapshotLookupResult {
  case none
  case unique(AcpAgentSnapshot)
  case ambiguous
}

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
    let descriptors = (try? await client.acpAgentDescriptors()) ?? Array(acpAgentDescriptorsByID.values)
    acpAgentDescriptorsByID = Dictionary(
      uniqueKeysWithValues: descriptors.map { ($0.id, $0) }
    )
    return descriptors
  }

  public func fetchRuntimeProbeResults() async -> AcpRuntimeProbeResponse? {
    guard let client else { return nil }
    return try? await client.runtimeProbeResults()
  }

  public func acpAgentSnapshot(for agentID: String) -> AcpAgentSnapshot? {
    guard case .unique(let snapshot) = acpAgentSnapshotLookup(for: agentID) else {
      return nil
    }
    return snapshot
  }

  private func acpAgentSnapshotLookup(for agentID: String) -> AcpAgentSnapshotLookupResult {
    var match: AcpAgentSnapshot?
    for snapshot in selectedAcpAgents where snapshot.agentId == agentID {
      guard match == nil else {
        return .ambiguous
      }
      match = snapshot
    }
    guard let match else {
      return .none
    }
    return .unique(match)
  }

  public func acpInspectSnapshot(for agentID: String) -> AcpAgentInspectSnapshot? {
    selectedAcpInspectState?.uniqueSnapshot(forAgentID: agentID)
  }

  public func acpRuntimeState(for agentID: String) -> AcpAgentRuntimeState? {
    let snapshot: AcpAgentSnapshot?
    let inspect: AcpAgentInspectSnapshot?
    switch acpAgentSnapshotLookup(for: agentID) {
    case .ambiguous:
      return nil
    case .none:
      snapshot = nil
      inspect = selectedAcpInspectState?.uniqueSnapshot(forAgentID: agentID)
    case .unique(let resolvedSnapshot):
      snapshot = resolvedSnapshot
      inspect = selectedAcpInspectState?.snapshot(for: AcpRuntimeIdentity(snapshot: resolvedSnapshot))
    }
    return AcpAgentRuntimeState(
      snapshot: snapshot,
      inspect: inspect,
      inspectSampledAt: selectedAcpInspectState?.sampledAt
    )
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
    let resolved = await performAcpPermissionResolution(
      batch: batch,
      decision: decision
    )
    if resolved {
      presentSuccessFeedback("Permission resolved")
    }
    return resolved
  }

  @discardableResult
  public func submitAcpPermissionDecisionAction(
    decisionID: String,
    actionID: String,
    decisionStore: DecisionStore? = nil
  ) async -> Bool {
    await withSupervisorAutoActionsSuppressed {
      await self.resolveAcpPermissionDecision(
        decisionID: decisionID,
        actionID: actionID,
        decisionStore: decisionStore
      )
    }
  }

  @discardableResult
  private func performAcpPermissionResolution(
    batch: AcpPermissionBatch,
    decision: AcpPermissionDecision
  ) async -> Bool {
    let actionName = "Permission resolved"
    guard let action = prepareSessionAction(named: actionName, sessionID: batch.sessionId) else {
      return false
    }
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
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  public func acpPermissionDecisionID(for batchID: String) -> String {
    AcpPermissionDecisionPayload.decisionID(for: batchID)
  }

  public func acpPermissionDecisionPayload(
    for batch: AcpPermissionBatch
  ) -> AcpPermissionDecisionPayload {
    let decisionID = acpPermissionDecisionID(for: batch.batchId)
    if let payload = acpPermissionDecisionPayloadsByDecisionID[decisionID] {
      return payload
    }
    return makeAcpPermissionDecisionPayload(for: batch)
  }

  public func acpPermissionDecisionPayload(for decisionID: String) -> AcpPermissionDecisionPayload?
  {
    acpPermissionDecisionPayloadsByDecisionID[decisionID]
  }

  public func acpPermissionResolutionState(for decisionID: String) -> BatchResolutionState? {
    acpPermissionResolutionStateByDecisionID[decisionID]
  }

  public func setAcpPermissionRequestSelection(
    decisionID: String,
    requestID: String,
    isSelected: Bool
  ) {
    guard
      var state = acpPermissionResolutionStateByDecisionID[decisionID]
        ?? acpPermissionDecisionPayloadsByDecisionID[decisionID]?.defaultResolutionState
    else {
      return
    }
    state.setSelected(isSelected, for: requestID)
    acpPermissionResolutionStateByDecisionID[decisionID] = state
  }

  public func clearAcpPermissionResolutionState() {
    acpPermissionResolutionStateByDecisionID = [:]
  }

  @discardableResult
  public func resolveAcpPermissionDecision(
    decisionID: String,
    actionID: String,
    decisionStore: DecisionStore? = nil
  ) async -> Bool {
    let activeDecisionStore = decisionStore ?? supervisorDecisionStore
    let payload: AcpPermissionDecisionPayload
    do {
      guard
        let resolvedPayload = try await resolveAcpPermissionPayload(
          decisionID: decisionID,
          decisionStore: activeDecisionStore
        )
      else {
        presentFailureFeedback("ACP permission decision is no longer available.")
        return false
      }
      payload = resolvedPayload
    } catch {
      reportAcpPermissionDecisionStoreFailure(
        operation: "load",
        decisionID: decisionID,
        error: error
      )
      presentFailureFeedback(
        "ACP permission decision could not be loaded from the Decisions queue. Refresh the session and try again."
      )
      return false
    }

    do {
      let result = try payload.actionDecision(
        for: actionID,
        resolutionState: acpPermissionResolutionStateByDecisionID[decisionID]
      )
      markAcpPermissionDecisionSubmission(decisionID: decisionID, submittedAt: Date())
      let resolved = await performAcpPermissionResolution(
        batch: payload.rawBatch,
        decision: result.decision
      )
      guard resolved else {
        markAcpPermissionDecisionSubmission(decisionID: decisionID, submittedAt: nil)
        return false
      }
      var needsDecisionStoreResync = false
      if let activeDecisionStore {
        do {
          try await activeDecisionStore.resolve(id: decisionID, outcome: result.outcome)
        } catch {
          needsDecisionStoreResync = true
          reportAcpPermissionDecisionStoreFailure(
            operation: "resolve",
            decisionID: decisionID,
            error: error
          )
          presentFailureFeedback(
            "ACP permission resolved, but the Decisions queue did not record the change. Refresh the session and try again."
          )
        }
      }
      removeAcpPermissionDecisionArtifacts(decisionID: decisionID)
      if needsDecisionStoreResync {
        scheduleAcpPermissionDecisionSync(staleDecisionIDs: [decisionID])
      } else {
        presentSuccessFeedback("Permission resolved")
      }
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

  private func acpToolCallTimelineMetadata(
    for payload: AcpEventBatchPayload
  ) -> AcpToolCallTimelineMetadata {
    let snapshot = selectedAcpAgents.first { $0.acpId == payload.acpId }
    let fallbackAgentID = payload.events.lazy.map(\.agent).first { !$0.isEmpty } ?? payload.acpId
    let descriptorID = snapshot?.agentId ?? fallbackAgentID
    let descriptor = acpAgentDescriptorsByID[descriptorID]
    return AcpToolCallTimelineMetadata(
      acpAgentId: payload.acpId,
      agentId: snapshot?.agentId ?? descriptor?.id ?? fallbackAgentID,
      displayName: snapshot?.displayName ?? descriptor?.displayName ?? snapshot?.agentId
        ?? fallbackAgentID,
      capabilityTags: descriptor?.capabilities ?? []
    )
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
    let resyncEntryID =
      "acp-resync-\(payload.bridgeEpoch)-\(payload.continuity)-\(payload.nextSeq)-\(resolvedSessionID)"
    let entry = TimelineEntry(
      entryId: resyncEntryID,
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
    if reason == .timeout {
      acpPermissionPendingDeadlineResolutionDecisionIDs.insert(decisionID)
      scheduleAcpPermissionDeadlineResolution(for: batch, decisionID: decisionID)
    } else {
      acpPermissionPendingDeadlineResolutionDecisionIDs.remove(decisionID)
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
    reconcileAcpPermissionDecisions()
    let protectedDecisionIDs: Set<String> = reason == .timeout ? [decisionID] : []
    scheduleAcpPermissionDecisionSync(
      staleDecisionIDs: [decisionID],
      protectedDecisionIDs: protectedDecisionIDs
    )
  }

  func resetSelectedAcpAgents() {
    selectedAcpAgents = []
    selectedAcpInspectState = nil
    liveToolCallAnnouncementRowIDs = []
    toolCallTimelineOverflowNotice = nil
    standaloneAcpPermissionBatches = []
    presentingAcpPermissionBatch = nil
    resolvingAcpPermissionBatchID = nil
    acpPermissionDecisionPayloadsByDecisionID = [:]
    acpPermissionResolutionStateByDecisionID = [:]
    acpPermissionPendingDeadlineResolutionDecisionIDs = []
    acpPermissionDecisionSyncTask?.cancel()
    acpPermissionDecisionSyncTask = nil
  }

  func refreshAcpAgents(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String
  ) async -> Bool {
    do {
      let measuredAgents = try await Self.measureOperation {
        try await client.managedAgents(sessionID: sessionID)
      }
      recordRequestSuccess()
      guard selectedSessionID == sessionID else {
        return true
      }
      replaceAcpAgents(
        AcpAgentsReconciledPayload(
          sessionId: sessionID,
          agents: measuredAgents.value.agents.compactMap(\.acp)
        ),
        allowAutoPresentation: shouldAutoPresentHydratedAcpPermissions()
      )
      return true
    } catch {
      guard selectedSessionID == sessionID else {
        return false
      }
      HarnessMonitorLogger.store.warning(
        "managed ACP refresh failed: \(error.localizedDescription, privacy: .public)"
      )
      return false
    }
  }

  func refreshAcpInspect(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String
  ) async -> Bool {
    do {
      let measuredInspect = try await Self.measureOperation {
        try await client.acpInspect(sessionID: sessionID)
      }
      recordRequestSuccess()
      guard selectedSessionID == sessionID else {
        return true
      }
      replaceAcpInspect(
        measuredInspect.value,
        sessionID: sessionID,
        sampledAt: Date()
      )
      return true
    } catch {
      guard selectedSessionID == sessionID else {
        return false
      }
      HarnessMonitorLogger.store.warning(
        "managed ACP inspect refresh failed: \(error.localizedDescription, privacy: .public)"
      )
      return false
    }
  }

  func recoverSelectedAcpAgentsAfterReconnect(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String
  ) async {
    async let refreshedAgents = refreshAcpAgents(using: client, sessionID: sessionID)
    async let refreshedInspect = refreshAcpInspect(using: client, sessionID: sessionID)
    _ = await (refreshedAgents, refreshedInspect)
  }

  private func shouldAutoPresentHydratedAcpPermissions() -> Bool {
    presentingAcpPermissionBatch != nil
      || ProcessInfo.processInfo.environment["HARNESS_MONITOR_PREVIEW_ACP_PERMISSION_ON_START"]
        == "1"
  }

  func reconcileAcpPermissionDecisions() {
    let previousPayloads = acpPermissionDecisionPayloadsByDecisionID
    var nextPayloads: [String: AcpPermissionDecisionPayload] = [:]
    var nextResolutionState: [String: BatchResolutionState] = [:]

    for batch in pendingAcpPermissionBatches {
      let payload = makeAcpPermissionDecisionPayload(for: batch)
      nextPayloads[payload.decisionID] = payload
      let requestIDs = payload.renderableBatch?.requests.map(\.id) ?? []
      let state =
        (acpPermissionResolutionStateByDecisionID[payload.decisionID]
        ?? payload.defaultResolutionState)
        .rebased(to: requestIDs)
      nextResolutionState[payload.decisionID] = state
    }

    if let resolvingBatchID = resolvingAcpPermissionBatchID,
      let resolvingPayload = previousPayloads.values.first(where: {
        $0.rawBatch.batchId == resolvingBatchID
      })
    {
      nextPayloads[resolvingPayload.decisionID] = resolvingPayload
      nextResolutionState[resolvingPayload.decisionID] =
        acpPermissionResolutionStateByDecisionID[resolvingPayload.decisionID]
        ?? resolvingPayload.defaultResolutionState
    }

    let staleDecisionIDs = Set(previousPayloads.keys).subtracting(nextPayloads.keys)
    acpPermissionDecisionPayloadsByDecisionID = nextPayloads
    acpPermissionResolutionStateByDecisionID = nextResolutionState
    scheduleAcpPermissionDecisionSync(staleDecisionIDs: staleDecisionIDs)
  }

  /// Preserve the currently presented batch whenever that batch is still pending and actively
  /// resolving; otherwise advance to the oldest remaining batch.
  ///
  /// UI-0 sticky-selection contract: new arrivals do not steal focus from the in-flight batch.
  func reconcilePresentedAcpPermissionBatch(allowAutoPresentation: Bool = true) {
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
    guard allowAutoPresentation || presentingAcpPermissionBatch != nil else {
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

  private func sortedAcpInspectSnapshots(
    _ snapshots: [AcpAgentInspectSnapshot]
  ) -> [AcpAgentInspectSnapshot] {
    snapshots.sorted {
      if $0.displayName != $1.displayName {
        return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
      }
      return $0.acpId < $1.acpId
    }
  }

  static func acpInspectSampledAt(from recordedAt: String?) -> Date {
    parsedAcpInspectRecordedAt(recordedAt) ?? Date()
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
    let currentByEntryID = Dictionary(uniqueKeysWithValues: current.map { ($0.entryId, $0) })
    var phaseLocations: [AcpToolCallPhaseKey: AcpToolCallPhaseLocation] = [:]
    var replacementsByCurrentEntryID: [String: TimelineEntry] = [:]
    var normalizedIncoming: [TimelineEntry] = []

    for entry in current {
      guard let metadata = entry.toolCallTimelineEntryMetadata() else {
        continue
      }
      phaseLocations[AcpToolCallPhaseKey(metadata: metadata)] = .current(entry.entryId)
    }

    for entry in incoming {
      guard let metadata = entry.toolCallTimelineEntryMetadata() else {
        normalizedIncoming.append(entry)
        continue
      }
      let phaseKey = AcpToolCallPhaseKey(metadata: metadata)
      guard let existingLocation = phaseLocations[phaseKey] else {
        phaseLocations[phaseKey] = .incoming(normalizedIncoming.count)
        normalizedIncoming.append(entry)
        continue
      }

      HarnessMonitorLogger.store.warning(
        """
        Coalescing duplicate ACP tool call id \(phaseKey.rowID, privacy: .public) \
        for \(phaseKey.status, privacy: .public) before timeline merge
        """
      )

      switch existingLocation {
      case .current(let currentEntryID):
        let existingEntry = replacementsByCurrentEntryID[currentEntryID]
          ?? currentByEntryID[currentEntryID]
          ?? entry
        replacementsByCurrentEntryID[currentEntryID] = Self.preferredTimelineEntry(
          existingEntry,
          over: entry
        )
      case .incoming(let index):
        normalizedIncoming[index] = Self.preferredTimelineEntry(
          normalizedIncoming[index],
          over: entry
        )
      }
    }

    let normalizedCurrent = current.map { entry in
      replacementsByCurrentEntryID[entry.entryId] ?? entry
    }

    return Dictionary(grouping: normalizedCurrent + normalizedIncoming, by: \.entryId)
      .compactMap { _, entries in entries.last }
      .sorted(by: Self.timelineEntrySortOrder)
  }

  private static func timelineEntrySortOrder(
    lhs: TimelineEntry,
    rhs: TimelineEntry
  ) -> Bool {
    if lhs.recordedAt != rhs.recordedAt {
      return lhs.recordedAt > rhs.recordedAt
    }
    if let lhsSequence = lhs.toolCallTimelineEntryMetadata()?.sequence,
      let rhsSequence = rhs.toolCallTimelineEntryMetadata()?.sequence,
      lhsSequence != rhsSequence
    {
      return lhsSequence > rhsSequence
    }
    return lhs.entryId < rhs.entryId
  }

  private static func preferredTimelineEntry(
    _ lhs: TimelineEntry,
    over rhs: TimelineEntry
  ) -> TimelineEntry {
    timelineEntrySortOrder(lhs: lhs, rhs: rhs) ? lhs : rhs
  }

  private func makeAcpPermissionDecisionPayload(
    for batch: AcpPermissionBatch
  ) -> AcpPermissionDecisionPayload {
    if let snapshot = selectedAcpAgents.first(where: { $0.acpId == batch.acpId }) {
      return AcpPermissionDecisionPayload.make(
        batch: batch,
        agentID: snapshot.agentId,
        agentName: snapshot.displayName
      )
    }
    return AcpPermissionDecisionPayload.make(
      batch: batch,
      agentID: batch.acpId,
      agentName: batch.acpId
    )
  }

  private func resolveAcpPermissionPayload(
    decisionID: String,
    decisionStore: DecisionStore?
  ) async throws -> AcpPermissionDecisionPayload? {
    if let payload = acpPermissionDecisionPayloadsByDecisionID[decisionID] {
      return payload
    }
    guard let decisionStore else {
      return nil
    }
    guard let decision = try await decisionStore.decision(id: decisionID) else {
      return nil
    }
    guard let payload = AcpPermissionDecisionPayload.decode(from: decision) else {
      return nil
    }
    acpPermissionDecisionPayloadsByDecisionID[decisionID] = payload
    if acpPermissionResolutionStateByDecisionID[decisionID] == nil {
      acpPermissionResolutionStateByDecisionID[decisionID] = payload.defaultResolutionState
    }
    return payload
  }

  private func markAcpPermissionDecisionSubmission(
    decisionID: String,
    submittedAt: Date?
  ) {
    guard
      var state = acpPermissionResolutionStateByDecisionID[decisionID]
        ?? acpPermissionDecisionPayloadsByDecisionID[decisionID]?.defaultResolutionState
    else {
      return
    }
    state.submittedAt = submittedAt
    acpPermissionResolutionStateByDecisionID[decisionID] = state
  }

  private func removeAcpPermissionDecisionArtifacts(decisionID: String) {
    acpPermissionDecisionPayloadsByDecisionID.removeValue(forKey: decisionID)
    acpPermissionResolutionStateByDecisionID.removeValue(forKey: decisionID)
  }

  private func scheduleAcpPermissionDecisionSync(
    staleDecisionIDs: Set<String>,
    protectedDecisionIDs: Set<String> = []
  ) {
    acpPermissionDecisionSyncTask?.cancel()
    guard let decisionStore = supervisorDecisionStore else {
      return
    }
    let payloads = acpPermissionDecisionPayloadsByDecisionID.values.sorted {
      if $0.rawBatch.createdAt != $1.rawBatch.createdAt {
        return $0.rawBatch.createdAt < $1.rawBatch.createdAt
      }
      return $0.decisionID < $1.decisionID
    }
    acpPermissionDecisionSyncTask = Task { @MainActor in
      var didPresentFailure = false
      let reportFailure: @MainActor (String, String?, any Error) -> Void = {
        operation, decisionID, error in
        self.reportAcpPermissionDecisionStoreFailure(
          operation: operation,
          decisionID: decisionID,
          error: error
        )
        if !didPresentFailure {
          self.presentFailureFeedback(
            "ACP decisions fell out of sync with the Decisions queue. Refresh the session and try again."
          )
          didPresentFailure = true
        }
      }
      for payload in payloads {
        guard !Task.isCancelled else {
          return
        }
        do {
          try await decisionStore.upsertOpen(payload.decisionDraft)
        } catch {
          reportFailure("upsert", payload.decisionID, error)
        }
      }
      guard !Task.isCancelled else {
        return
      }
      let activeDecisionIDs = Set(payloads.map(\.decisionID))
      let openDecisions: [Decision]
      do {
        openDecisions = try await decisionStore.openDecisions()
      } catch {
        reportFailure("list-open", nil, error)
        return
      }
      let staleACPDecisionIDs = Set(
        openDecisions
          .filter { $0.ruleID == AcpPermissionDecisionPayload.ruleID }
          .map(\.id)
      )
      .subtracting(activeDecisionIDs)
      .union(staleDecisionIDs)
      .subtracting(protectedDecisionIDs)
      .subtracting(self.acpPermissionPendingDeadlineResolutionDecisionIDs)
      for decisionID in staleACPDecisionIDs.sorted() {
        guard !Task.isCancelled else {
          return
        }
        do {
          try await decisionStore.dismiss(id: decisionID)
        } catch {
          reportFailure("dismiss", decisionID, error)
        }
      }
    }
  }

  private func scheduleAcpPermissionDeadlineResolution(
    for batch: AcpPermissionBatch,
    decisionID: String
  ) {
    Task { @MainActor in
      guard let decisionStore = self.supervisorDecisionStore else {
        self.acpPermissionPendingDeadlineResolutionDecisionIDs.remove(decisionID)
        return
      }

      do {
        guard let decision = try await decisionStore.decision(id: decisionID) else {
          self.acpPermissionPendingDeadlineResolutionDecisionIDs.remove(decisionID)
          return
        }
        try await decisionStore.resolve(
          id: decisionID,
          outcome: DecisionOutcome(
            chosenActionID: nil,
            note: "client_deadline_exceeded"
          )
        )
        appendAcpPermissionDeadlineAudit(
          for: batch,
          decisionID: decisionID,
          agentID: decision.agentID
        )
        supervisorDecisionRefreshTick &+= 1
      } catch {
        reportAcpPermissionDecisionStoreFailure(
          operation: "timeout-resolve",
          decisionID: decisionID,
          error: error
        )
        acpPermissionPendingDeadlineResolutionDecisionIDs.remove(decisionID)
        scheduleAcpPermissionDecisionSync(staleDecisionIDs: [decisionID])
        return
      }

      acpPermissionPendingDeadlineResolutionDecisionIDs.remove(decisionID)
    }
  }

  private func appendAcpPermissionDeadlineAudit(
    for batch: AcpPermissionBatch,
    decisionID: String,
    agentID: String?
  ) {
    guard let container = modelContext?.container else {
      return
    }

    let context = ModelContext(container)
    context.autosaveEnabled = false
    context.insert(
      SupervisorEvent(
        id: UUID().uuidString,
        tickID: "acp-timeout-\(batch.batchId)",
        kind: "acp_permission_deadline_expired",
        ruleID: AcpPermissionDecisionPayload.ruleID,
        severity: .warn,
        payloadJSON: encodeAcpPermissionDeadlineAuditPayload(
          decisionID: decisionID,
          batchID: batch.batchId,
          sessionID: batch.sessionId,
          agentID: agentID,
          managedAgentID: batch.acpId
        )
      )
    )
    do {
      try context.save()
    } catch {
      HarnessMonitorLogger.supervisorWarning(
        "supervisor.audit_append_failed error=\(String(describing: error))"
      )
    }
  }

  private func encodeAcpPermissionDeadlineAuditPayload(
    decisionID: String,
    batchID: String,
    sessionID: String,
    agentID: String?,
    managedAgentID: String
  ) -> String {
    let payload = AcpPermissionDeadlineAuditPayload(
      decisionID: decisionID,
      batchID: batchID,
      sessionID: sessionID,
      agentID: agentID,
      managedAgentID: managedAgentID,
      reason: "client_deadline_exceeded"
    )
    guard
      let data = try? JSONEncoder().encode(payload),
      let json = String(data: data, encoding: .utf8)
    else {
      return #"{"reason":"client_deadline_exceeded"}"#
    }
    return json
  }

  private func reportAcpPermissionDecisionStoreFailure(
    operation: String,
    decisionID: String?,
    error: any Error
  ) {
    let resolvedDecisionID = decisionID ?? "none"
    HarnessMonitorLogger.store.error(
      """
      ACP decision store operation failed: operation=\(operation, privacy: .public); \
      decisionID=\(resolvedDecisionID, privacy: .public); \
      error=\(error.localizedDescription, privacy: .public)
      """
    )
  }

  private func dropAcpInspectSnapshot(acpID: String, agentID: String) {
    guard let selectedAcpInspectState else {
      return
    }
    self.selectedAcpInspectState = selectedAcpInspectState.filtered(removingMatching: {
      identity in
      identity.acpID == acpID || identity.agentID == agentID
    })
  }

  private func reconcileAcpInspectState(
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

  private static func parsedAcpInspectRecordedAt(_ recordedAt: String?) -> Date? {
    guard let recordedAt else {
      return nil
    }
    return acpInspectRecordedAtFormatterWithFractionalSeconds.date(from: recordedAt)
      ?? acpInspectRecordedAtFormatter.date(from: recordedAt)
  }

  nonisolated(unsafe) private static let acpInspectRecordedAtFormatterWithFractionalSeconds:
    ISO8601DateFormatter =
      {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
      }()

  nonisolated(unsafe) private static let acpInspectRecordedAtFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

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

private struct AcpPermissionDeadlineAuditPayload: Encodable {
  let decisionID: String
  let batchID: String
  let sessionID: String
  let agentID: String?
  let managedAgentID: String
  let reason: String
}

private struct AcpToolCallPhaseKey: Hashable {
  let rowID: String
  let status: String

  init(metadata: ToolCallTimelineEntryMetadata) {
    rowID = metadata.rowID
    status = metadata.status
  }
}

private enum AcpToolCallPhaseLocation {
  case current(String)
  case incoming(Int)
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
