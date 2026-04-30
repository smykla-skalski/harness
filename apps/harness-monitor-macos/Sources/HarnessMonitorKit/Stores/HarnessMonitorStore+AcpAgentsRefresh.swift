import Foundation

extension HarnessMonitorStore {
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
    let previousPayloads = acpPermissionPayloadsByDecisionID
    var nextPayloads: [String: AcpPermissionDecisionPayload] = [:]
    var nextResolutionState: [String: BatchResolutionState] = [:]

    for batch in pendingAcpPermissionBatches {
      let payload = makeAcpPermissionDecisionPayload(for: batch)
      if acpPermissionTerminalOutcomesByID[payload.decisionID] != nil {
        continue
      }
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

    for decisionID in acpPermissionPendingTimeoutDecisionIDs {
      guard let timeoutPayload = previousPayloads[decisionID] else {
        continue
      }
      nextPayloads[decisionID] = timeoutPayload
      nextResolutionState[decisionID] =
        acpPermissionResolutionStateByDecisionID[decisionID]
        ?? timeoutPayload.defaultResolutionState
    }
    for decisionID in acpPermissionPendingShutdownDecisionIDs {
      guard let shutdownPayload = previousPayloads[decisionID] else {
        continue
      }
      nextPayloads[decisionID] = shutdownPayload
      nextResolutionState[decisionID] =
        acpPermissionResolutionStateByDecisionID[decisionID]
        ?? shutdownPayload.defaultResolutionState
    }

    let staleDecisionIDs = Set(previousPayloads.keys).subtracting(nextPayloads.keys)
    acpPermissionPayloadsByDecisionID = nextPayloads
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
}
