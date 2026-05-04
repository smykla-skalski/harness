import Foundation

extension HarnessMonitorStore {
  private enum AcpInspectRefreshOutcome {
    case available
    case unavailable(String)
    case failed(String)
    case ignored
  }

  public func runAcpBridgeDoctor() async {
    guard isDiagnosticsRefreshInFlight == false else {
      return
    }
    isDiagnosticsRefreshInFlight = true
    defer { isDiagnosticsRefreshInFlight = false }

    guard let client, let sessionID = selectedSessionID else {
      await refreshDiagnostics()
      return
    }

    switch await refreshAcpInspectOutcome(
      using: client,
      sessionID: sessionID,
      shouldScheduleRecovery: false
    ) {
    case .available:
      if acpBridgeBannerState == nil {
        presentSuccessFeedback("ACP bridge recovered")
      } else {
        presentFailureFeedback(acpHostBridgeFailureMessage())
      }
    case .unavailable(let message), .failed(let message):
      presentFailureFeedback(message)
    case .ignored:
      break
    }
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
      clearHostBridgeIssue(for: "acp")
      guard selectedSessionID == sessionID else {
        return true
      }
      replaceAcpAgents(
        AcpAgentsReconciledPayload(
          sessionId: sessionID,
          agents: measuredAgents.value.agents.compactMap(\.acp)
        ),
        sampledAt: Date(),
        allowAutoPresentation: shouldAutoPresentHydratedAcpPermissions()
      )
      return true
    } catch {
      guard selectedSessionID == sessionID else {
        return false
      }
      if let apiError = error as? HarnessMonitorAPIError,
        case .server(let code, _) = apiError,
        code == 501 || code == 503
      {
        self.markHostBridgeIssue(for: "acp", statusCode: code)
        HarnessMonitorLogger.store.info(
          "managed ACP refresh unavailable: \(self.acpHostBridgeFailureMessage(), privacy: .public)"
        )
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
    sessionID: String,
    shouldScheduleRecovery: Bool = true
  ) async -> Bool {
    switch await refreshAcpInspectOutcome(
      using: client,
      sessionID: sessionID,
      shouldScheduleRecovery: shouldScheduleRecovery
    ) {
    case .available:
      return true
    case .unavailable(let message):
      HarnessMonitorLogger.store.info(
        "managed ACP inspect unavailable: \(message, privacy: .public)"
      )
      return false
    case .failed(let message):
      HarnessMonitorLogger.store.warning(
        "managed ACP inspect refresh failed: \(message, privacy: .public)"
      )
      return false
    case .ignored:
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

  private func refreshAcpInspectOutcome(
    using client: any HarnessMonitorClientProtocol,
    sessionID: String,
    shouldScheduleRecovery: Bool
  ) async -> AcpInspectRefreshOutcome {
    do {
      let measuredInspect = try await Self.measureOperation {
        try await client.acpInspect(sessionID: sessionID)
      }
      guard selectedSessionID == sessionID else {
        return .ignored
      }

      let response = measuredInspect.value
      if response.available {
        recordRequestSuccess()
        clearHostBridgeIssue(for: "acp")
      } else if daemonStatus?.manifest?.sandboxed == true {
        markHostBridgeIssue(for: "acp", statusCode: 503)
      }
      replaceAcpInspect(
        response,
        sessionID: sessionID,
        sampledAt: Date(),
        shouldScheduleRecovery: shouldScheduleRecovery
      )
      guard response.available == false else {
        return .available
      }
      return .unavailable(response.issueMessage ?? acpHostBridgeFailureMessage())
    } catch {
      guard selectedSessionID == sessionID else {
        return .ignored
      }
      if let apiError = error as? HarnessMonitorAPIError,
        case .server(let code, _) = apiError,
        code == 501 || code == 503
      {
        self.markHostBridgeIssue(for: "acp", statusCode: code)
        return .unavailable(acpHostBridgeFailureMessage())
      }
      return .failed(error.localizedDescription)
    }
  }

  func reconcileAcpPermissionDecisions(extraStaleDecisionIDs: Set<String> = []) {
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

    let staleDecisionIDs =
      Set(previousPayloads.keys)
      .subtracting(nextPayloads.keys)
      .union(extraStaleDecisionIDs)
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
