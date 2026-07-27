import HarnessMonitorKit

/// Carries the guided flow across app launches. The rail's own state dies with
/// the view, so without this a restart mid-process reopens on the first step.
extension TaskBoardStepRailView {
  /// What the next launch needs to reopen on this step: the pinned item and the
  /// plan Pick loaded for it. Built only when the flow actually changed, never
  /// on the body path.
  var stepFlowSnapshot: TaskBoardStepFlowSnapshot? {
    guard let lockedItemID = stepRailState.lockedItemID else { return nil }
    let picked = stepRailState.pickedSelection
    let matchesFlow = picked?.item.id == lockedItemID
    return TaskBoardStepFlowSnapshot(
      lockedItemID: lockedItemID,
      pickedPlan: matchesFlow ? picked?.plan : nil,
      pickedItemUpdatedAt: matchesFlow ? picked?.item.updatedAt : nil
    )
  }

  /// Bumps when the board items or the orchestrator status change, which is when
  /// a stored flow that had nothing to resolve against can resolve. Cheaper than
  /// `.task(id:)`, which would spawn and cancel a task per board snapshot.
  var stepFlowRestorationRevision: UInt64 {
    store.contentUI.dashboard.taskBoardSnapshotRevision
  }

  func restoreStepFlowIfNeeded() {
    let state = stepRailState
    if !state.hasLoadedPersistedFlow {
      state.hasLoadedPersistedFlow = true
      state.pendingRestoredFlow = TaskBoardStepFlowStore.load(from: flowDefaults)
    }
    guard let pending = state.pendingRestoredFlow else { return }
    // A flow started in this session outranks a stored one.
    guard state.lockedItemID == nil else {
      state.pendingRestoredFlow = nil
      return
    }
    guard
      let restored = TaskBoardStepFlowRestoration.restoredFlow(
        snapshot: pending,
        items: taskBoardItems
      )
    else {
      return
    }
    state.adoptRestoredFlow(itemID: restored.itemID, pickedSelection: restored.pickedSelection)
  }

  func persistStepFlow() {
    TaskBoardStepFlowStore.save(stepFlowSnapshot, in: flowDefaults)
  }

  /// Step mode ended, so there is no flow left to resume.
  func endStepFlow() {
    stepRailState.reset()
    persistStepFlow()
  }
}
