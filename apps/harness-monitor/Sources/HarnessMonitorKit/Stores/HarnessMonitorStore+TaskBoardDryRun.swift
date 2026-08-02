import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func setTaskBoardDryRunDefault(enabled: Bool) async -> Bool {
    guard
      let client,
      globalTaskBoardOrchestratorStatus != nil
    else {
      return false
    }
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
      let settings = try await client.updateTaskBoardOrchestratorSettings(
        request: TaskBoardOrchestratorSettingsUpdateRequest(dryRunDefault: enabled)
      )
      confirmTaskBoardOrchestratorSettings(settings)
      applyTaskBoardOrchestratorSettings(settings)
      recordRequestSuccess()
      return true
    } catch {
      presentFailureFeedback(error.localizedDescription)
      return false
    }
  }

  private func applyTaskBoardOrchestratorSettings(
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
