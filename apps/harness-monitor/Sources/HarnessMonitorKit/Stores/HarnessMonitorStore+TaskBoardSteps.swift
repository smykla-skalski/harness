import Foundation

extension HarnessMonitorStore {
  public func pickTaskBoardDispatch() async -> TaskBoardDispatchSelection? {
    guard let client else {
      return nil
    }
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

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
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

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

  /// Step-mode dispatch is one user action that the daemon runs as two phases:
  /// reserve (place the held delivery) then deliver (start the worker). Treat
  /// the pair as a single outcome so a failed delivery is never left standing
  /// next to a "dispatch succeeded" record that is never reconciled.
  ///
  /// The reserve is an internal prepare: it must not toast success or record a
  /// finished dispatch, because in step mode the worker has not started. The
  /// daemon's held-dispatch claim is the authority on whether a hold exists, so
  /// a stale dashboard snapshot is never trusted to mean "safe to deliver".
  public func prepareAndDeliverTaskBoardDispatch(
    request: TaskBoardDispatchRequest,
    isAlreadyHeld: Bool = false
  ) async -> TaskBoardDispatchDelivery? {
    guard let client, let itemID = request.itemId else {
      presentFailureFeedback("Task-board delivery requires a selected item")
      return nil
    }

    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

    beginTaskBoardDashboardRefreshDeferral()
    let delivery = await prepareAndDeliverTaskBoardDispatchBody(
      request: request,
      itemID: itemID,
      isAlreadyHeld: isAlreadyHeld,
      using: client
    )
    await finishTaskBoardDashboardRefreshDeferral(using: client)
    return delivery
  }

  private func prepareAndDeliverTaskBoardDispatchBody(
    request: TaskBoardDispatchRequest,
    itemID: String,
    isAlreadyHeld: Bool,
    using client: any HarnessMonitorClientProtocol
  ) async -> TaskBoardDispatchDelivery? {
    var didReserveItem = false
    if !isAlreadyHeld {
      do {
        let measuredSummary = try await Self.measureOperation {
          try await client.dispatchTaskBoard(request: request)
        }
        recordRequestSuccess()
        didReserveItem = measuredSummary.value.applied.contains { $0.boardItemId == itemID }
      } catch {
        presentFailureFeedback(error.localizedDescription)
        return nil
      }
    }

    // The daemon decides whether a reserve holds the worker or starts it, from
    // its own step mode rather than from this request, so the held set is the
    // only trustworthy answer. Claiming without checking is what surfaced as
    // the "is not held" conflict.
    guard await taskBoardDeliveryIsHeld(itemID: itemID, using: client) else {
      presentUnheldTaskBoardDeliveryFeedback(itemID: itemID, didReserveItem: didReserveItem)
      return nil
    }
    return await claimHeldTaskBoardDelivery(
      itemID: itemID,
      dryRun: request.dryRun,
      using: client
    )
  }

  /// A failed check falls through to the claim so a genuinely held delivery is
  /// never dropped; the daemon stays the final authority either way.
  private func taskBoardDeliveryIsHeld(
    itemID: String,
    using client: any HarnessMonitorClientProtocol
  ) async -> Bool {
    do {
      let measuredStatus = try await Self.measureOperation {
        try await client.taskBoardOrchestratorStatus()
      }
      return measuredStatus.value.heldDispatches.items.contains { $0.boardItemId == itemID }
    } catch {
      return true
    }
  }

  /// Nothing is held, so there is no delivery to claim. A reserve that applied
  /// the item started its worker outright, which is what happens when the
  /// daemon's step mode is off; anything else never reserved it at all.
  private func presentUnheldTaskBoardDeliveryFeedback(itemID: String, didReserveItem: Bool) {
    guard didReserveItem else {
      presentFailureFeedback(
        """
        No held delivery to claim for task-board item '\(itemID)'; it may have already been \
        delivered, been cancelled, or was never reserved in step mode
        """
      )
      return
    }
    presentSuccessFeedback("Dispatched task-board item")
  }

  private func claimHeldTaskBoardDelivery(
    itemID: String,
    dryRun: Bool,
    using client: any HarnessMonitorClientProtocol
  ) async -> TaskBoardDispatchDelivery? {
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
      presentSuccessFeedback(
        dryRun ? "Previewed task-board delivery" : "Prepared and delivered task-board item"
      )
      return delivery
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return nil
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
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

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
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

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
    beginDaemonAction()
    beginTaskBoardAction()
    defer {
      endDaemonAction()
      endTaskBoardAction()
    }

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
