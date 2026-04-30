import Foundation

extension HarnessMonitorStore {
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

  public func acpPermissionDecisionID(for batchID: String) -> String {
    AcpPermissionDecisionPayload.decisionID(for: batchID)
  }

  public func acpPermissionDecisionPayload(
    for batch: AcpPermissionBatch
  ) -> AcpPermissionDecisionPayload {
    let decisionID = acpPermissionDecisionID(for: batch.batchId)
    if let payload = acpPermissionPayloadsByDecisionID[decisionID] {
      return payload
    }
    return makeAcpPermissionDecisionPayload(for: batch)
  }

  public func acpPermissionDecisionPayload(for decisionID: String) -> AcpPermissionDecisionPayload?
  {
    acpPermissionPayloadsByDecisionID[decisionID]
  }

  public func acpPermissionResolutionState(for decisionID: String) -> BatchResolutionState? {
    acpPermissionResolutionStateByDecisionID[decisionID]
  }

  public func acpPermissionLastSignalAt(sessionID: String?) -> Date? {
    guard let sessionID else {
      return nil
    }
    return acpPermissionLastSignalAtBySessionID[sessionID]
  }

  public func setAcpPermissionRequestSelection(
    decisionID: String,
    requestID: String,
    isSelected: Bool
  ) {
    guard
      var state = acpPermissionResolutionStateByDecisionID[decisionID]
        ?? acpPermissionPayloadsByDecisionID[decisionID]?.defaultResolutionState
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
        """
        ACP permission decision could not be loaded from the Decisions queue. Refresh the \
        session and try again.
        """
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
            """
            ACP permission resolved, but the Decisions queue did not record the change. \
            Refresh the session and try again.
            """
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
}
