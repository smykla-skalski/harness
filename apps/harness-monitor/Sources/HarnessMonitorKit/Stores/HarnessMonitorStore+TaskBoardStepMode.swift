import Foundation

extension HarnessMonitorStore {
  @discardableResult
  public func setTaskBoardStepMode(enabled: Bool) async -> Bool {
    guard
      let client,
      let currentStatus = globalTaskBoardOrchestratorStatus
    else {
      return false
    }

    let generation = beginTaskBoardStepModeMutation(
      enabled: enabled,
      currentSettings: currentStatus.settings
    )
    await acquireTaskBoardStepModeRequestLock()
    defer { releaseTaskBoardStepModeRequestLock() }

    guard generation == taskBoardRuntimeState.stepModeMutation.latestGeneration else {
      return true
    }
    if let settings = taskBoardRuntimeState.stepModeMutation.lastAuthoritativeSettings,
      settings.stepMode == enabled
    {
      finishTaskBoardStepModeSuccess(
        settings: settings,
        enabled: enabled,
        generation: generation
      )
      return true
    }

    do {
      let settings = try await client.updateTaskBoardOrchestratorSettings(
        request: TaskBoardOrchestratorSettingsUpdateRequest(stepMode: enabled)
      )
      taskBoardRuntimeState.stepModeMutation.lastAuthoritativeSettings = settings
      confirmTaskBoardOrchestratorSettings(settings)
      guard generation == taskBoardRuntimeState.stepModeMutation.latestGeneration else {
        return true
      }
      finishTaskBoardStepModeSuccess(
        settings: settings,
        enabled: enabled,
        generation: generation
      )
      return true
    } catch {
      guard generation == taskBoardRuntimeState.stepModeMutation.latestGeneration else {
        return true
      }
      finishTaskBoardStepModeFailure(error, generation: generation)
      return false
    }
  }

  private func beginTaskBoardStepModeMutation(
    enabled: Bool,
    currentSettings: TaskBoardOrchestratorSettings
  ) -> UInt64 {
    if taskBoardRuntimeState.stepModeMutation.desiredValue == nil {
      taskBoardRuntimeState.stepModeMutation.lastAuthoritativeSettings = currentSettings
      // One begin/end pair per mutation chain: `desiredValue` only goes from
      // nil back to nil once, in `finishTaskBoardStepModeMutation`, even
      // though overlapping toggles bump `latestGeneration` and re-enter this
      // function multiple times before that chain resolves.
      beginTaskBoardAction()
    }
    taskBoardRuntimeState.stepModeMutation.latestGeneration &+= 1
    taskBoardRuntimeState.stepModeMutation.desiredValue = enabled
    isDaemonActionInFlight = true
    return taskBoardRuntimeState.stepModeMutation.latestGeneration
  }

  private func acquireTaskBoardStepModeRequestLock() async {
    guard taskBoardRuntimeState.stepModeMutation.isRequestLocked else {
      taskBoardRuntimeState.stepModeMutation.isRequestLocked = true
      return
    }
    await withCheckedContinuation { continuation in
      taskBoardRuntimeState.stepModeMutation.requestWaiters.append(continuation)
    }
  }

  private func releaseTaskBoardStepModeRequestLock() {
    guard !taskBoardRuntimeState.stepModeMutation.requestWaiters.isEmpty else {
      taskBoardRuntimeState.stepModeMutation.isRequestLocked = false
      return
    }
    taskBoardRuntimeState.stepModeMutation.requestWaiters.removeFirst().resume()
  }

  private func finishTaskBoardStepModeSuccess(
    settings: TaskBoardOrchestratorSettings,
    enabled: Bool,
    generation: UInt64
  ) {
    guard generation == taskBoardRuntimeState.stepModeMutation.latestGeneration else { return }
    recordRequestSuccess()
    presentSuccessFeedback(
      enabled ? "Enabled task-board step mode" : "Disabled task-board step mode"
    )
    finishTaskBoardStepModeMutation(settings: settings)
  }

  private func finishTaskBoardStepModeFailure(
    _ error: any Error,
    generation: UInt64
  ) {
    guard generation == taskBoardRuntimeState.stepModeMutation.latestGeneration else { return }
    presentFailureFeedback(error.localizedDescription)
    finishTaskBoardStepModeMutation(
      settings: taskBoardRuntimeState.stepModeMutation.lastAuthoritativeSettings
    )
  }

  private func finishTaskBoardStepModeMutation(
    settings: TaskBoardOrchestratorSettings?
  ) {
    let updatedStatus = settings.flatMap { settings in
      globalTaskBoardOrchestratorStatus.map {
        taskBoardOrchestratorStatus($0, applying: settings)
      }
    }
    let didChangeStatus = updatedStatus != nil && updatedStatus != globalTaskBoardOrchestratorStatus
    withUISyncBatch {
      if let updatedStatus {
        globalTaskBoardOrchestratorStatus = updatedStatus
      }
      isDaemonActionInFlight = false
      endTaskBoardAction()
    }
    if didChangeStatus {
      scheduleTaskBoardSnapshotCacheWrite(
        items: globalTaskBoardItems,
        orchestratorStatus: updatedStatus
      )
    }
    taskBoardRuntimeState.stepModeMutation.desiredValue = nil
    taskBoardRuntimeState.stepModeMutation.lastAuthoritativeSettings = nil
  }

  func confirmTaskBoardOrchestratorSettings(
    _ settings: TaskBoardOrchestratorSettings
  ) {
    taskBoardRuntimeState.stepModeMutation.confirmationRevision &+= 1
    taskBoardRuntimeState.stepModeMutation.confirmedSettings = settings
  }

  func reconcileTaskBoardOrchestratorStatus(
    _ status: TaskBoardOrchestratorStatus?,
    snapshotConfirmationRevision: UInt64
  ) -> TaskBoardOrchestratorStatus? {
    let stepModeState = taskBoardRuntimeState.stepModeMutation
    guard
      snapshotConfirmationRevision < stepModeState.confirmationRevision,
      let confirmedSettings = stepModeState.confirmedSettings,
      let baseStatus = status ?? globalTaskBoardOrchestratorStatus
    else {
      return status
    }
    return taskBoardOrchestratorStatus(baseStatus, applying: confirmedSettings)
  }

  private func taskBoardOrchestratorStatus(
    _ status: TaskBoardOrchestratorStatus,
    applying settings: TaskBoardOrchestratorSettings
  ) -> TaskBoardOrchestratorStatus {
    TaskBoardOrchestratorStatus(
      enabled: status.enabled,
      running: status.running,
      stepMode: settings.stepMode,
      heldDispatches: status.heldDispatches,
      currentTick: status.currentTick,
      lastRun: status.lastRun,
      workflowExecutionCounts: status.workflowExecutionCounts,
      settings: settings
    )
  }
}
