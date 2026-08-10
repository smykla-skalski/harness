import Foundation

private struct InitialTaskBoardConfirmationContext {
  let access: TaskBoardClientAccess
  let generation: UInt64
  let preservedItemIDs: Set<String>
  let preservedStatus: Bool
  let deadline: ContinuousClock.Instant
}

extension HarnessMonitorStore {
  func cancelInitialTaskBoardConfirmationRefresh() {
    initialTaskBoardConfirmationGeneration &+= 1
    initialTaskBoardConfirmationTask?.cancel()
    initialTaskBoardConfirmationTask = nil
  }

  func scheduleInitialTaskBoardConfirmationRefresh(
    using client: any HarnessMonitorClientProtocol,
    preservedItemIDs: Set<String>,
    preservedStatus: Bool
  ) {
    guard !preservedItemIDs.isEmpty || preservedStatus else { return }
    guard initialTaskBoardConfirmationGracePeriod > .zero else { return }
    guard
      let access = availableTaskBoardClientAccess,
      access.client === client
    else { return }
    cancelInitialTaskBoardConfirmationRefresh()
    let generation = initialTaskBoardConfirmationGeneration
    let deadline = ContinuousClock.now.advanced(by: initialTaskBoardConfirmationGracePeriod)
    initialTaskBoardConfirmationTask = Task(priority: .utility) { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.initialTaskBoardConfirmationGeneration == generation {
          self.initialTaskBoardConfirmationTask = nil
        }
      }
      await self.runInitialTaskBoardConfirmationRefresh(
        using: client,
        context: InitialTaskBoardConfirmationContext(
          access: access,
          generation: generation,
          preservedItemIDs: preservedItemIDs,
          preservedStatus: preservedStatus,
          deadline: deadline
        )
      )
    }
  }

  private func runInitialTaskBoardConfirmationRefresh(
    using client: any HarnessMonitorClientProtocol,
    context: InitialTaskBoardConfirmationContext
  ) async {
    var retryInterval = taskBoardConfirmationRetryInterval
    while confirmationRefreshIsCurrent(context) {
      do {
        try await Task.sleep(for: retryInterval)
      } catch {
        return
      }
      guard
        confirmationRefreshIsCurrent(context),
        connectionState == .online || connectionState == .connecting,
        taskBoardAccessIsCurrent(context.access)
      else { return }
      let stepModeConfirmationRevision =
        taskBoardRuntimeState.stepModeMutation.confirmationRevision
      let positionMutationGeneration = taskBoardRuntimeState.positionMutation.generation
      let snapshot = await Self.loadTaskBoardRefreshSnapshot(
        using: client,
        stepModeConfirmationRevision: stepModeConfirmationRevision,
        includeItems: !context.preservedItemIDs.isEmpty,
        includeOrchestratorStatus: context.preservedStatus,
        includeProjects: false
      )
      guard confirmationRefreshIsCurrent(context) else { return }
      let reachedDeadline = ContinuousClock.now >= context.deadline
      let tick = evaluateTaskBoardConfirmationTick(
        snapshot: snapshot,
        preservedItemIDs: context.preservedItemIDs,
        preservedStatus: context.preservedStatus,
        reachedDeadline: reachedDeadline,
        positionMutationGeneration: positionMutationGeneration
      )
      if tick.shouldKeepWaiting && !reachedDeadline {
        retryInterval = min(retryInterval * 2, .seconds(1))
        continue
      }
      guard tick.shouldApply else { return }
      guard confirmationRefreshIsCurrent(context) else { return }
      commitTaskBoardConfirmationTick(tick)
      return
    }
  }

  private func confirmationRefreshIsCurrent(
    _ context: InitialTaskBoardConfirmationContext
  ) -> Bool {
    !Task.isCancelled
      && initialTaskBoardConfirmationGeneration == context.generation
      && taskBoardAccessIsCurrent(context.access)
  }

  func evaluateTaskBoardConfirmationTick(
    snapshot: TaskBoardRefreshSnapshot,
    preservedItemIDs: Set<String>,
    preservedStatus: Bool,
    reachedDeadline: Bool,
    positionMutationGeneration: UInt64
  ) -> TaskBoardConfirmationTick {
    var tick = TaskBoardConfirmationTick(
      resolvedItems: globalTaskBoardItems,
      resolvedStatus: globalTaskBoardOrchestratorStatus,
      automationSnapshot: nil,
      positionMutationGeneration: positionMutationGeneration,
      shouldApply: false,
      shouldKeepWaiting: false
    )
    if !preservedItemIDs.isEmpty {
      resolveTaskBoardItems(
        snapshot: snapshot,
        preservedItemIDs: preservedItemIDs,
        reachedDeadline: reachedDeadline,
        tick: &tick
      )
    }
    if preservedStatus {
      resolveTaskBoardStatus(
        snapshot: snapshot,
        reachedDeadline: reachedDeadline,
        tick: &tick
      )
    }
    return tick
  }

  func resolveTaskBoardItems(
    snapshot: TaskBoardRefreshSnapshot,
    preservedItemIDs: Set<String>,
    reachedDeadline: Bool,
    tick: inout TaskBoardConfirmationTick
  ) {
    guard let measuredItems = snapshot.items.measured else {
      if !reachedDeadline { tick.shouldKeepWaiting = true }
      return
    }
    let liveIDs = Set(measuredItems.value.map(\.id))
    if preservedItemIDs.isSubset(of: liveIDs) || reachedDeadline {
      tick.resolvedItems = measuredItems.value
      tick.shouldApply = true
    } else {
      tick.shouldKeepWaiting = true
    }
  }

  func resolveTaskBoardStatus(
    snapshot: TaskBoardRefreshSnapshot,
    reachedDeadline: Bool,
    tick: inout TaskBoardConfirmationTick
  ) {
    guard let measuredStatus = snapshot.orchestratorStatus.measured else {
      if !reachedDeadline { tick.shouldKeepWaiting = true }
      return
    }
    if measuredStatus.value != nil || reachedDeadline {
      tick.automationSnapshot = measuredStatus.value?.automation
      tick.resolvedStatus = reconcileTaskBoardOrchestratorStatus(
        measuredStatus.value,
        snapshotConfirmationRevision: snapshot.stepModeConfirmationRevision
      )
      tick.shouldApply = true
    } else {
      tick.shouldKeepWaiting = true
    }
  }

  func commitTaskBoardConfirmationTick(_ tick: TaskBoardConfirmationTick) {
    let resolvedItems = taskBoardItemsPreservingPositionMutation(
      tick.resolvedItems,
      positionMutationGeneration: tick.positionMutationGeneration
    )
    let didChangeTaskBoardSnapshot =
      globalTaskBoardItems != resolvedItems
      || globalTaskBoardOrchestratorStatus?.withoutAutomationSnapshot
        != tick.resolvedStatus?.withoutAutomationSnapshot
    withUISyncBatch {
      globalTaskBoardItems = resolvedItems
      globalTaskBoardOrchestratorStatus = tick.resolvedStatus
      mergeTaskBoardAutomationSnapshot(tick.automationSnapshot)
    }
    if didChangeTaskBoardSnapshot
      && taskBoardRuntimeState.positionMutation.pendingTokens.isEmpty
    {
      scheduleTaskBoardSnapshotCacheWrite(
        items: resolvedItems,
        orchestratorStatus: tick.resolvedStatus
      )
    }
  }
}
