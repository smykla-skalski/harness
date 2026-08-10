import Foundation

extension HarnessMonitorStore {
  func cancelInitialTaskBoardConfirmationRefresh() {
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
    cancelInitialTaskBoardConfirmationRefresh()
    let deadline = ContinuousClock.now.advanced(by: initialTaskBoardConfirmationGracePeriod)
    initialTaskBoardConfirmationTask = Task(priority: .utility) { @MainActor [weak self] in
      guard let self else { return }
      defer { self.initialTaskBoardConfirmationTask = nil }
      await self.runInitialTaskBoardConfirmationRefresh(
        using: client,
        preservedItemIDs: preservedItemIDs,
        preservedStatus: preservedStatus,
        deadline: deadline
      )
    }
  }

  private func runInitialTaskBoardConfirmationRefresh(
    using client: any HarnessMonitorClientProtocol,
    preservedItemIDs: Set<String>,
    preservedStatus: Bool,
    deadline: ContinuousClock.Instant
  ) async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: taskBoardConfirmationRetryInterval)
      } catch {
        return
      }
      guard connectionState == .online || connectionState == .connecting else { return }
      let stepModeConfirmationRevision =
        taskBoardRuntimeState.stepModeMutation.confirmationRevision
      let positionMutationGeneration = taskBoardRuntimeState.positionMutation.generation
      let snapshot = await Self.loadTaskBoardRefreshSnapshot(
        using: client,
        stepModeConfirmationRevision: stepModeConfirmationRevision
      )
      let reachedDeadline = ContinuousClock.now >= deadline
      let tick = evaluateTaskBoardConfirmationTick(
        snapshot: snapshot,
        preservedItemIDs: preservedItemIDs,
        preservedStatus: preservedStatus,
        reachedDeadline: reachedDeadline,
        positionMutationGeneration: positionMutationGeneration
      )
      if tick.shouldKeepWaiting && !reachedDeadline { continue }
      guard tick.shouldApply else { return }
      commitTaskBoardConfirmationTick(tick)
      return
    }
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
