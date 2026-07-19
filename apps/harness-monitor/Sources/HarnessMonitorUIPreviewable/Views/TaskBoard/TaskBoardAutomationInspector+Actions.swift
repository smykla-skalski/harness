import HarnessMonitorKit

extension TaskBoardAutomationInspector {
  func enqueueVisibleLoads() {
    guard isActive, dashboard.connectionState == .online else { return }
    enqueueMetrics(force: false)
    if state.surface == .history {
      enqueueHistory(force: false)
    }
  }

  func enqueueHistoryAndMetricsRefresh() {
    enqueueHistory(force: true)
    enqueueMetrics(force: true)
  }

  func enqueueHistory(force: Bool) {
    guard isActive, dashboard.connectionState == .online,
      let request = state.beginInitialHistoryLoad(force: force)
    else {
      return
    }
    let state = state
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading task-board automation history") {
        let response = await store.taskBoardAutomationRuns(before: request.before)
        await MainActor.run {
          state.completeHistory(request: request, response: response)
        }
      }
    )
  }

  func enqueueOlderHistory() {
    guard isActive, dashboard.connectionState == .online,
      let request = state.beginOlderHistoryLoad()
    else {
      return
    }
    let state = state
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading older task-board automation runs") {
        let response = await store.taskBoardAutomationRuns(before: request.before)
        await MainActor.run {
          state.completeHistory(request: request, response: response)
        }
      }
    )
  }

  func enqueueRunDetail(runID: String) {
    guard isActive, dashboard.connectionState == .online, isWriteAuthorized,
      let request = state.beginDetailLoad(runID: runID)
    else {
      return
    }
    let state = state
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading task-board automation run detail") {
        let detail = await store.taskBoardAutomationRunDetail(runID: request.runID)
        await MainActor.run {
          state.completeDetail(request: request, detail: detail)
        }
      }
    )
  }

  func enqueueMetrics(force: Bool) {
    guard isActive, dashboard.connectionState == .online,
      let request = state.beginMetricsLoad(force: force)
    else {
      return
    }
    let state = state
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Loading task-board automation metrics") {
        let metrics = await store.taskBoardAutomationMetrics()
        await MainActor.run {
          state.completeMetrics(request: request, metrics: metrics)
        }
      }
    )
  }

  func enqueueStart() {
    enqueueControl(.start, title: "Starting task-board automation") {
      await store.startTaskBoardOrchestrator()
    }
  }

  func enqueueStop() {
    enqueueControl(.stop, title: "Stopping task-board automation") {
      await store.stopTaskBoardOrchestrator()
    }
  }

  func enqueueRunOnce() {
    enqueueControl(.runOnce, title: "Running task-board automation once") {
      await store.runTaskBoardOrchestratorOnce()
    }
  }

  private func enqueueControl(
    _ action: TaskBoardAutomationInspectorAction,
    title: String,
    operation: @escaping @MainActor @Sendable () async -> Bool
  ) {
    guard isPresentationCurrent,
      cachedPresentation.controlAvailability.controlBlockedReason == nil,
      let request = state.beginAction(action)
    else {
      return
    }

    let state = state
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: title) {
        guard
          let succeeded = await performCurrentTaskBoardAutomationControl(
            state: state,
            request: request,
            operation: operation
          )
        else {
          return
        }
        await MainActor.run {
          if state.completeAction(request), succeeded {
            state.resetRemoteData()
            enqueueVisibleLoads()
          }
        }
      }
    )
  }
}

@MainActor
private func performCurrentTaskBoardAutomationControl(
  state: TaskBoardAutomationInspectorState,
  request: TaskBoardAutomationActionRequest,
  operation: @escaping @MainActor @Sendable () async -> Bool
) async -> Bool? {
  guard state.isCurrentAction(request) else { return nil }
  return await operation()
}
