import Foundation

extension HarnessMonitorStore {
  public func pickTaskBoardDispatch() async -> TaskBoardDispatchSelection? {
    guard let client else {
      return nil
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let measuredResult = try await Self.measureOperation {
        try await client.pickTaskBoardDispatch(request: TaskBoardDispatchPickRequest())
      }
      recordRequestSuccess()
      guard let selection = measuredResult.value.selection else {
        presentSuccessFeedback("No ready task-board item to pick")
        return nil
      }
      presentSuccessFeedback("Picked top task-board item")
      return selection
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  public func deliverTaskBoardDispatch(
    itemID: String,
    dryRun: Bool = false,
    refreshDashboard: Bool = true
  ) async -> TaskBoardDispatchDelivery? {
    guard let client else {
      return nil
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let measuredDelivery = try await Self.measureOperation {
        try await client.deliverTaskBoardDispatch(
          request: TaskBoardDispatchDeliverRequest(itemId: itemID, dryRun: dryRun)
        )
      }
      recordRequestSuccess()
      let delivery = measuredDelivery.value
      if !dryRun {
        mergeTaskBoardItem(delivery.applied.item)
      }
      if refreshDashboard && !dryRun {
        await refreshTaskBoardDashboardSnapshot(using: client)
      }
      presentSuccessFeedback(dryRun ? "Previewed task-board delivery" : "Delivered task-board item")
      return delivery
    } catch {
      if refreshDashboard && !dryRun {
        await refreshTaskBoardDashboardSnapshot(using: client)
      }
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  public func prepareAndDeliverTaskBoardDispatch(
    request: TaskBoardDispatchRequest,
    isAlreadyHeld: Bool = false
  ) async -> TaskBoardDispatchDelivery? {
    guard let client, let itemID = request.itemId else {
      presentFailureFeedback("Task-board delivery requires a selected item")
      return nil
    }

    beginTaskBoardDashboardRefreshDeferral()
    let isPrepared: Bool
    if isAlreadyHeld {
      isPrepared = true
    } else {
      isPrepared = await dispatchTaskBoard(request: request, refreshDashboard: false)
    }
    let delivery: TaskBoardDispatchDelivery?
    if isPrepared {
      delivery = await deliverTaskBoardDispatch(
        itemID: itemID,
        dryRun: request.dryRun,
        refreshDashboard: false
      )
    } else {
      delivery = nil
    }
    await finishTaskBoardDashboardRefreshDeferral(using: client)
    return delivery
  }

  @discardableResult
  public func setTaskBoardStepMode(enabled: Bool) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      _ = try await client.updateTaskBoardOrchestratorSettings(
        request: TaskBoardOrchestratorSettingsUpdateRequest(stepMode: enabled)
      )
      recordRequestSuccess()
      await refreshTaskBoardDashboardSnapshot(using: client)
      presentSuccessFeedback(
        enabled ? "Enabled task-board step mode" : "Disabled task-board step mode"
      )
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  public func policyApprovalGrants() async -> [PolicyApprovalGrant]? {
    guard let client else {
      return nil
    }
    do {
      let measuredGrants = try await Self.measureOperation {
        try await client.policyApprovalGrants()
      }
      recordRequestSuccess()
      return measuredGrants.value
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  public func resolvePolicyApprovalGrant(
    grantID: String,
    approve: Bool,
    actor: String? = nil
  ) async -> PolicyApprovalGrant? {
    guard let client else {
      return nil
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let measuredGrant = try await Self.measureOperation {
        try await client.resolvePolicyApprovalGrant(
          request: PolicyApprovalGrantResolveRequest(
            grantId: grantID,
            approve: approve,
            actor: actor
          )
        )
      }
      recordRequestSuccess()
      presentSuccessFeedback(approve ? "Approved policy grant" : "Denied policy grant")
      return measuredGrant.value
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  public func revokePolicyApprovalGrant(
    grantID: String,
    actor: String? = nil
  ) async -> PolicyApprovalGrant? {
    guard let client else {
      return nil
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let measuredGrant = try await Self.measureOperation {
        try await client.revokePolicyApprovalGrant(
          request: PolicyApprovalGrantRevokeRequest(grantId: grantID, actor: actor)
        )
      }
      recordRequestSuccess()
      presentSuccessFeedback("Revoked policy grant")
      return measuredGrant.value
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  @discardableResult
  public func setPolicyCanvasSpawnRequiresLivePolicy(enabled: Bool) async -> Bool {
    await mutatePolicySpawnGate(
      actionName: enabled ? "Enabled fail-closed spawn policy" : "Disabled fail-closed spawn policy"
    ) { client in
      try await client.setPolicyCanvasSpawnRequiresLivePolicy(
        request: PolicyCanvasSetSpawnRequiresLivePolicyRequest(enabled: enabled)
      )
    }
  }

  @discardableResult
  public func setPolicyCanvasSpawnKillSwitch(enabled: Bool) async -> Bool {
    await mutatePolicySpawnGate(
      actionName: enabled ? "Engaged spawn kill switch" : "Disengaged spawn kill switch"
    ) { client in
      try await client.setPolicyCanvasSpawnKillSwitch(
        request: PolicyCanvasSetSpawnKillSwitchRequest(enabled: enabled)
      )
    }
  }

  private func mutatePolicySpawnGate(
    actionName: String,
    mutation:
      @escaping @Sendable (any HarnessMonitorClientProtocol) async throws
      -> PolicyCanvasWorkspace
  ) async -> Bool {
    guard let client else {
      return false
    }
    isDaemonActionInFlight = true
    defer { isDaemonActionInFlight = false }

    do {
      let measuredWorkspace = try await Self.measureOperation {
        try await mutation(client)
      }
      recordRequestSuccess()
      await syncPolicyCanvasWorkspace(measuredWorkspace.value, using: client)
      presentSuccessFeedback(actionName)
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
}
