import HarnessMonitorKit

struct TaskBoardOrchestratorPresentation {
  enum SummarySource {
    case lastRun(TaskBoardOrchestratorRunSummary)
    case standaloneEvaluation(TaskBoardEvaluationSummary)
  }

  enum FailedStage: String, Equatable {
    case dispatch = "Dispatch"
    case evaluation = "Evaluation"
    case automation = "Automation"
  }

  let status: TaskBoardOrchestratorStatus
  let taskBoardItems: [TaskBoardItem]
  let localHostProjectTypes: [String]?

  init(
    status: TaskBoardOrchestratorStatus,
    taskBoardItems: [TaskBoardItem],
    localHostProjectTypes: [String]? = nil
  ) {
    self.status = status
    self.taskBoardItems = taskBoardItems
    self.localHostProjectTypes = localHostProjectTypes
  }

  func summarySource(
    latestEvaluation: TaskBoardEvaluationSummary?,
    baselineRunID: String?
  ) -> SummarySource? {
    if let latestEvaluation, status.lastRun?.runId == baselineRunID {
      return .standaloneEvaluation(latestEvaluation)
    }
    if let lastRun = status.lastRun {
      return .lastRun(lastRun)
    }
    return nil
  }

  var workflowCounts: [TaskBoardWorkflowCountPresentation] {
    var totals: [TaskBoardWorkflowStatus: Int] = [:]
    for item in status.workflowExecutionCounts where item.count >= 1 {
      totals[item.status, default: 0] += item.count
    }

    let completedIdleCount = taskBoardItems.count { item in
      item.status.canonicalPersistedStatus == .done
        && (item.workflow?.status ?? .idle) == .idle
        && routesToLocalHost(item)
    }
    if let idleCount = totals[.idle] {
      totals[.idle] = max(0, idleCount - completedIdleCount)
    }

    return TaskBoardWorkflowStatus.allCases.compactMap { workflowStatus in
      if workflowStatus == .idle, localHostProjectTypes == nil {
        return nil
      }
      guard let count = totals[workflowStatus], count >= 1 else {
        return nil
      }
      return TaskBoardWorkflowCountPresentation(status: workflowStatus, count: count)
    }
  }

  private func routesToLocalHost(_ item: TaskBoardItem) -> Bool {
    guard let localHostProjectTypes else { return false }
    return TaskBoardHostMachine.acceptsAny(
      machineProjectTypes: localHostProjectTypes,
      itemTargetProjectTypes: item.targetProjectTypes
    )
  }

  static func appliedItemCount(for run: TaskBoardOrchestratorRunSummary) -> Int {
    var itemIDs = Set(run.dispatch?.applied.map(\.boardItemId) ?? [])
    let updatedItemIDs = Set(
      run.evaluation?.records.filter(\.updated).map(\.boardItemId) ?? []
    )
    itemIDs.formUnion(updatedItemIDs)

    let unrepresentedUpdates = max(
      0,
      (run.evaluation?.updated ?? 0) - updatedItemIDs.count
    )
    return itemIDs.count + unrepresentedUpdates
  }

  static func failedStage(for run: TaskBoardOrchestratorRunSummary) -> FailedStage? {
    guard run.status == .failed else { return nil }
    guard run.dispatch != nil else { return .dispatch }
    guard run.evaluation != nil else { return .evaluation }
    return .automation
  }

  static func showsManualSteps(
    for status: TaskBoardOrchestratorStatus,
    scopeSessionID: String?,
    hasStore: Bool
  ) -> Bool {
    scopeSessionID == nil && hasStore && status.stepMode
  }

  static func stateTitle(for status: TaskBoardOrchestratorStatus) -> String {
    if status.stepMode {
      return "Paused (Step Mode)"
    }
    if !status.enabled {
      return "Disabled"
    }
    if status.running {
      return "Running"
    }
    return "Idle"
  }
}

struct TaskBoardWorkflowCountPresentation: Identifiable, Equatable {
  let status: TaskBoardWorkflowStatus
  let count: Int

  var id: String { status.rawValue }
}
