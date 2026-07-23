import HarnessMonitorKit

struct TaskBoardAutomationInspectorActions: Equatable {
  let store: HarnessMonitorStore
  let state: TaskBoardAutomationInspectorState
  let isActive: Bool

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.store === rhs.store
      && lhs.state === rhs.state
      && lhs.isActive == rhs.isActive
  }

  @MainActor
  func enqueueVisibleLoads() {
    guard isActive, isOnline else { return }
    enqueueMetrics(force: false)
    if state.surface == .history {
      enqueueHistory(force: false)
    }
  }

  @MainActor
  func enqueueHistoryAndMetricsRefresh() {
    enqueueHistory(force: true)
    enqueueMetrics(force: true)
  }

  @MainActor
  private func enqueueHistory(force: Bool) {
    guard isActive, isOnline,
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

  @MainActor
  func enqueueOlderHistory() {
    guard isActive, isOnline,
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

  @MainActor
  func enqueueRunDetail(runID: String) {
    guard isActive, isOnline, isWriteAuthorized,
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

  @MainActor
  private func enqueueMetrics(force: Bool) {
    guard isActive, isOnline,
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

  @MainActor
  func enqueueControl(
    _ action: TaskBoardAutomationInspectorAction,
    isPresentationCurrent: Bool,
    controlBlockedReason: String?
  ) {
    guard isPresentationCurrent, controlBlockedReason == nil,
      let request = state.beginAction(action)
    else {
      return
    }

    let state = state
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: controlTitle(action)) {
        guard
          let succeeded = await performCurrentTaskBoardAutomationControl(
            store: store,
            state: state,
            request: request
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

  @MainActor
  func requestForceCancel(
    _ target: TaskBoardAutomationCancelTarget,
    isPresentationCurrent: Bool,
    forceCancelBlockedReason: String?,
    cachedTargets: [TaskBoardAutomationCancelTargetPresentation],
    currentTargets: [TaskBoardAutomationCancelTarget]
  ) {
    if let rejection = forceCancelRejection(
      target,
      isPresentationCurrent: isPresentationCurrent,
      forceCancelBlockedReason: forceCancelBlockedReason,
      cachedTargets: cachedTargets,
      currentTargets: currentTargets
    ) {
      store.presentFailureFeedback(rejection)
      return
    }
    state.pendingForceCancelTarget = target
  }

  @MainActor
  func enqueueForceCancel(
    target: TaskBoardAutomationCancelTarget,
    isPresentationCurrent: Bool,
    forceCancelBlockedReason: String?,
    cachedTargets: [TaskBoardAutomationCancelTargetPresentation],
    currentTargets: [TaskBoardAutomationCancelTarget]
  ) {
    if let rejection = forceCancelRejection(
      target,
      isPresentationCurrent: isPresentationCurrent,
      forceCancelBlockedReason: forceCancelBlockedReason,
      cachedTargets: cachedTargets,
      currentTargets: currentTargets
    ) {
      store.presentFailureFeedback(rejection)
      return
    }
    guard let request = state.beginAction(.forceCancel) else {
      store.presentFailureFeedback("Another automation action is in progress")
      return
    }

    let state = state
    HarnessMonitorAsyncWorkQueue.shared.submit(
      .init(title: "Force-cancelling remote task-board workflow") {
        let succeeded = await store.forceCancelTaskBoardAutomation(
          request: TaskBoardAutomationForceCancelRequest(
            target: target,
            reason: "Cancelled from Harness Monitor"
          )
        )
        await MainActor.run {
          if state.completeAction(request), succeeded {
            state.resetRemoteData()
            enqueueVisibleLoads()
          }
        }
      }
    )
  }

  @MainActor
  private var isOnline: Bool {
    store.contentUI.dashboard.connectionState == .online
  }

  @MainActor
  private var isWriteAuthorized: Bool {
    guard let profile = store.remoteDaemonProfile else { return true }
    return profile.status == .active
      && profile.role != .viewer
      && profile.scopes.contains("write")
  }

  private func controlTitle(_ action: TaskBoardAutomationInspectorAction) -> String {
    switch action {
    case .start:
      "Starting task-board automation"
    case .stop:
      "Stopping task-board automation"
    case .runOnce:
      "Running task-board automation once"
    case .forceCancel:
      "Force-cancelling remote task-board workflow"
    }
  }

  private func hasCurrentCancelTarget(
    _ target: TaskBoardAutomationCancelTarget,
    cachedTargets: [TaskBoardAutomationCancelTargetPresentation],
    currentTargets: [TaskBoardAutomationCancelTarget]
  ) -> Bool {
    cachedTargets.contains { $0.target == target }
      && currentTargets.contains(target)
  }

  @MainActor
  private func forceCancelRejection(
    _ target: TaskBoardAutomationCancelTarget,
    isPresentationCurrent: Bool,
    forceCancelBlockedReason: String?,
    cachedTargets: [TaskBoardAutomationCancelTargetPresentation],
    currentTargets: [TaskBoardAutomationCancelTarget]
  ) -> String? {
    if !isPresentationCurrent {
      return "Automation status changed. Refresh and try again."
    }
    if let forceCancelBlockedReason {
      return forceCancelBlockedReason
    }
    if target.cancelPending {
      return "Cancellation is already pending"
    }
    if !hasCurrentCancelTarget(
      target,
      cachedTargets: cachedTargets,
      currentTargets: currentTargets
    ) {
      return "Cancellation target changed. Refresh and try again."
    }
    return state.activeAction == nil ? nil : "Another automation action is in progress"
  }
}

@MainActor
private func performCurrentTaskBoardAutomationControl(
  store: HarnessMonitorStore,
  state: TaskBoardAutomationInspectorState,
  request: TaskBoardAutomationActionRequest
) async -> Bool? {
  guard state.isCurrentAction(request) else { return nil }
  switch request.action {
  case .start:
    return await store.startTaskBoardOrchestrator()
  case .stop:
    return await store.stopTaskBoardOrchestrator()
  case .runOnce:
    return await store.runTaskBoardOrchestratorOnce()
  case .forceCancel:
    return nil
  }
}
