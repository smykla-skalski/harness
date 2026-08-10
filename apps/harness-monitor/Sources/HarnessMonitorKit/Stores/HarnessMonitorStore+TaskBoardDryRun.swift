import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func setTaskBoardDryRunDefault(enabled: Bool) async -> Bool {
    guard
      let access = availableTaskBoardClientAccess,
      globalTaskBoardOrchestratorStatus != nil
    else {
      return false
    }
    let client = access.client
    guard
      !isTaskBoardBusy || taskBoardRuntimeState.orchestratorSettingsMutation.isLocked
    else {
      return false
    }

    beginDaemonAction()
    beginTaskBoardAction()
    await acquireTaskBoardOrchestratorSettingsMutationLock()
    defer {
      releaseTaskBoardOrchestratorSettingsMutationLock()
      endDaemonAction()
      endTaskBoardAction()
    }

    do {
      try requireCurrentTaskBoardClientAccess(access)
      let settings = try await client.updateTaskBoardOrchestratorSettings(
        request: TaskBoardOrchestratorSettingsUpdateRequest(dryRunDefault: enabled)
      )
      try requireCurrentTaskBoardClientAccess(access)
      confirmTaskBoardOrchestratorSettings(settings)
      applyTaskBoardOrchestratorSettings(settings)
      recordRequestSuccess()
      return true
    } catch is CancellationError {
      return false
    } catch {
      guard taskBoardAccessIsCurrent(access) else { return false }
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  func applyTaskBoardOrchestratorSettings(
    _ settings: TaskBoardOrchestratorSettings
  ) {
    guard let status = globalTaskBoardOrchestratorStatus else { return }
    let updatedStatus = taskBoardOrchestratorStatus(status, applying: settings)
    let didChangeStatus = updatedStatus != status
    withUISyncBatch {
      globalTaskBoardOrchestratorStatus = updatedStatus
    }
    if didChangeStatus {
      scheduleTaskBoardSnapshotCacheWrite(
        items: globalTaskBoardItems,
        orchestratorStatus: updatedStatus
      )
    }
  }
}
