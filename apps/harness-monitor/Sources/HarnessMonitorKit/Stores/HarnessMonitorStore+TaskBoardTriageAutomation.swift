import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func setTaskBoardTriageAutomation(enabled: Bool) async -> Bool {
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
        request: TaskBoardOrchestratorSettingsUpdateRequest(
          triageAutomationEnabled: enabled
        )
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
}
