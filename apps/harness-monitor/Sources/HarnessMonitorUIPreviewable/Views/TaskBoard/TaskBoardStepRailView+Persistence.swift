import HarnessMonitorKit

/// Carries the guided flow across app launches. The rail's own state dies with
/// the view, so without this a restart mid-process reopens on the first step.
extension TaskBoardStepRailView {
  /// What the next launch needs to reopen on this step: the pinned item and the
  /// plan Pick loaded for it.
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

  /// Bumps when the board items or the orchestrator status change, which is
  /// when a stored flow that had nothing to resolve against can resolve.
  var stepFlowRestorationRevision: UInt64 {
    store.contentUI.dashboard.taskBoardSnapshotRevision
  }

  func restoreStepFlowIfNeeded() {
    let state = stepRailState
    guard !state.hasRestoredPersistedFlow else { return }
    // A flow started in this session outranks a stored one; nothing to restore.
    guard state.lockedItemID == nil else {
      state.hasRestoredPersistedFlow = true
      return
    }
    guard
      let restored = TaskBoardStepFlowRestoration.restoredFlow(
        snapshot: TaskBoardStepFlowStore.load(from: flowDefaults),
        items: taskBoardItems
      )
    else {
      return
    }
    state.hasRestoredPersistedFlow = true
    state.lockedItemID = restored.itemID
    state.pickedSelection = restored.pickedSelection
  }

  func persistStepFlow() {
    TaskBoardStepFlowStore.save(stepFlowSnapshot, in: flowDefaults)
  }

  /// Step mode ended, so there is no flow left to resume.
  func endStepFlow() {
    stepRailState.reset()
    TaskBoardStepFlowStore.save(nil, in: flowDefaults)
  }
}
