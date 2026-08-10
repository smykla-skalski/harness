import Foundation

extension HarnessMonitorStore {
  public func pickTaskBoardDispatch() async -> TaskBoardDispatchSelection? {
    guard let access = availableTaskBoardClientAccess else {
      return nil
    }
    let client = access.client
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
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      guard let selection = measuredResult.value.selection else {
        presentSuccessFeedback("No ready task-board item to pick")
        return nil
      }
      presentSuccessFeedback("Picked top task-board item")
      return selection
    } catch is CancellationError {
      return nil
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return nil }
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  public func deliverTaskBoardDispatch(
    itemID: String,
    dryRun: Bool = false,
    refreshDashboard: Bool = true
  ) async -> TaskBoardDispatchDelivery? {
    guard let access = availableTaskBoardClientAccess else {
      return nil
    }
    let client = access.client
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
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      let delivery = measuredDelivery.value
      if !dryRun {
        mergeTaskBoardItem(delivery.applied.item)
      }
      if refreshDashboard && !dryRun {
        guard await refreshTaskBoardDashboardSnapshot(using: client, access: access) else {
          return nil
        }
      }
      presentSuccessFeedback(dryRun ? "Previewed task-board delivery" : "Delivered task-board item")
      return delivery
    } catch is CancellationError {
      return nil
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return nil }
      if refreshDashboard && !dryRun {
        guard await refreshTaskBoardDashboardSnapshot(using: client, access: access) else {
          return nil
        }
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
    guard let access = availableTaskBoardClientAccess, let itemID = request.itemId else {
      presentFailureFeedback("Task-board delivery requires a selected item")
      return nil
    }
    let client = access.client

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
      access: access
    )
    await finishTaskBoardDashboardRefreshDeferral(using: client, access: access)
    return delivery
  }

  private func prepareAndDeliverTaskBoardDispatchBody(
    request: TaskBoardDispatchRequest,
    itemID: String,
    isAlreadyHeld: Bool,
    access: TaskBoardClientAccess
  ) async -> TaskBoardDispatchDelivery? {
    let client = access.client
    var didReserveItem = false
    var reserveFailure: String?
    if !isAlreadyHeld {
      do {
        let measuredSummary = try await Self.measureOperation {
          try await client.dispatchTaskBoard(request: request)
        }
        try requireCurrentTaskBoardClientAccess(access)
        recordRequestSuccess()
        let summary = measuredSummary.value
        didReserveItem = summary.applied.contains { $0.boardItemId == itemID }
        reserveFailure = summary.failures.first { $0.boardItemId == itemID }?.message
      } catch is CancellationError {
        return nil
      } catch {
        guard taskBoardAccessIsCurrent(access) else { return nil }
        presentFailureFeedback(error.localizedDescription)
        return nil
      }
    }

    // The daemon decides whether a reserve holds the worker or starts it, from
    // its own step mode rather than from this request, so the held set is the
    // only trustworthy answer. Claiming without checking is what surfaced as
    // the "is not held" conflict.
    guard await taskBoardDeliveryIsHeld(itemID: itemID, access: access) else {
      if (try? requireCurrentTaskBoardClientAccess(access)) != nil {
        presentUnheldTaskBoardDeliveryFeedback(
          itemID: itemID,
          didReserveItem: didReserveItem,
          reserveFailure: reserveFailure
        )
      }
      return nil
    }
    return await claimHeldTaskBoardDelivery(
      itemID: itemID,
      dryRun: request.dryRun,
      access: access
    )
  }

  /// A failed check falls through to the claim so a genuinely held delivery is
  /// never dropped; the daemon stays the final authority either way.
  private func taskBoardDeliveryIsHeld(
    itemID: String,
    access: TaskBoardClientAccess
  ) async -> Bool {
    let client = access.client
    do {
      let measuredStatus = try await Self.measureOperation {
        try await client.taskBoardOrchestratorStatus()
      }
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      return measuredStatus.value.heldDispatches.items.contains { $0.boardItemId == itemID }
    } catch is CancellationError {
      return false
    } catch {
      return true
    }
  }

  /// Nothing is held, so there is no delivery to claim. When the reserve reported
  /// a failure for this item, that reason is the honest thing to show instead of a
  /// generic message - a missing project dir or an admission block reads as "never
  /// reserved" otherwise. A reserve that applied the item started its worker
  /// outright (the daemon's step mode was off); anything else never reserved it.
  private func presentUnheldTaskBoardDeliveryFeedback(
    itemID: String,
    didReserveItem: Bool,
    reserveFailure: String?
  ) {
    if let reserveFailure {
      presentFailureFeedback(reserveFailure)
      return
    }
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
    access: TaskBoardClientAccess
  ) async -> TaskBoardDispatchDelivery? {
    let client = access.client
    do {
      try requireCurrentTaskBoardClientAccess(access)
      let measuredDelivery = try await Self.measureOperation {
        try await client.deliverTaskBoardDispatch(
          request: TaskBoardDispatchDeliverRequest(itemId: itemID, dryRun: dryRun)
        )
      }
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      let delivery = measuredDelivery.value
      if !dryRun {
        mergeTaskBoardItem(delivery.applied.item)
      }
      presentSuccessFeedback(
        dryRun ? "Previewed task-board delivery" : "Prepared and delivered task-board item"
      )
      return delivery
    } catch is CancellationError {
      return nil
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return nil }
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  public func policyApprovalGrants() async -> [PolicyApprovalGrant]? {
    await readTaskBoard { client in
      try await client.policyApprovalGrants()
    }
  }

  public func resolvePolicyApprovalGrant(
    grantID: String,
    approve: Bool,
    actor: String? = nil
  ) async -> PolicyApprovalGrant? {
    guard let access = availableTaskBoardClientAccess else {
      return nil
    }
    let client = access.client
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
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      presentSuccessFeedback(approve ? "Approved policy grant" : "Denied policy grant")
      return measuredGrant.value
    } catch is CancellationError {
      return nil
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return nil }
      presentFailureFeedback(error.localizedDescription)
      return nil
    }
  }

  public func revokePolicyApprovalGrant(
    grantID: String,
    actor: String? = nil
  ) async -> PolicyApprovalGrant? {
    guard let access = availableTaskBoardClientAccess else {
      return nil
    }
    let client = access.client
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
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      presentSuccessFeedback("Revoked policy grant")
      return measuredGrant.value
    } catch is CancellationError {
      return nil
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return nil }
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
      actionName: enabled ? "Engaged automation kill switch" : "Disengaged automation kill switch"
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
    await withSerializedTaskBoardPolicyPublication(cancellationResult: false) {
      await mutatePolicySpawnGateSerialized(
        actionName: actionName,
        mutation: mutation
      )
    }
  }

  private func mutatePolicySpawnGateSerialized(
    actionName: String,
    mutation:
      @escaping @Sendable (any HarnessMonitorClientProtocol) async throws
      -> PolicyCanvasWorkspace
  ) async -> Bool {
    guard let access = availableTaskBoardClientAccess else {
      return false
    }
    let client = access.client
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
      try requireCurrentTaskBoardClientAccess(access)
      recordRequestSuccess()
      guard
        await syncPolicyCanvasWorkspace(
          measuredWorkspace.value,
          using: client,
          taskBoardAccess: access
        )
      else { return false }
      try requireCurrentTaskBoardClientAccess(access)
      presentSuccessFeedback(actionName)
      return true
    } catch is CancellationError {
      return false
    } catch {
      guard (try? requireCurrentTaskBoardClientAccess(access)) != nil else {
        return false
      }
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }
}
