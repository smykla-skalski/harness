import HarnessMonitorKit

struct TaskBoardOrchestratorPresentation: Equatable, Sendable {
  enum SummarySource: Equatable, Sendable {
    case lastRun(
      TaskBoardOrchestratorRunSummary,
      appliedCount: Int,
      evaluation: TaskBoardEvaluationPillPresentation?
    )
    case standaloneEvaluation(TaskBoardEvaluationPillPresentation)
  }

  enum FailedStage: String, Equatable {
    case dispatch = "Dispatch"
    case evaluation = "Evaluation"
    case automation = "Automation"
  }

  let summarySource: SummarySource?
  let workflowCounts: [TaskBoardWorkflowCountPresentation]

  init(
    status: TaskBoardOrchestratorStatus,
    taskBoardItems: [TaskBoardItem],
    localHostProjectTypes: [String]? = nil,
    latestEvaluation: TaskBoardEvaluationSummary? = nil,
    latestEvaluationBaselineRunID: String? = nil,
    repositoryScopeIsKnown: Bool = false
  ) {
    let scopedItemIDs = repositoryScopeIsKnown ? Set(taskBoardItems.map(\.id)) : nil
    workflowCounts = Self.workflowCounts(
      status: status,
      taskBoardItems: taskBoardItems,
      localHostProjectTypes: localHostProjectTypes,
      repositoryScopeIsKnown: repositoryScopeIsKnown
    )
    summarySource = Self.summarySource(
      status: status,
      latestEvaluation: latestEvaluation,
      latestEvaluationBaselineRunID: latestEvaluationBaselineRunID,
      scopedItemIDs: scopedItemIDs
    )
  }

  private static func workflowCounts(
    status: TaskBoardOrchestratorStatus,
    taskBoardItems: [TaskBoardItem],
    localHostProjectTypes: [String]?,
    repositoryScopeIsKnown: Bool
  ) -> [TaskBoardWorkflowCountPresentation] {
    if repositoryScopeIsKnown, let localHostProjectTypes {
      let totals = taskBoardItems.reduce(
        into: [TaskBoardWorkflowStatus: Int]()
      ) { totals, item in
        guard
          item.deletedAt == nil,
          routesToLocalHost(item, projectTypes: localHostProjectTypes)
        else {
          return
        }
        let workflowStatus = item.workflow?.status ?? .idle
        guard
          workflowStatus != .idle
            || item.status.canonicalPersistedStatus != .done
        else {
          return
        }
        totals[workflowStatus, default: 0] += 1
      }
      return countPresentations(totals)
    }

    var totals: [TaskBoardWorkflowStatus: Int] = [:]
    for item in status.workflowExecutionCounts where item.count >= 1 {
      totals[item.status, default: 0] += item.count
    }

    let completedIdleCount = taskBoardItems.count { item in
      item.status.canonicalPersistedStatus == .done
        && (item.workflow?.status ?? .idle) == .idle
        && localHostProjectTypes.map {
          routesToLocalHost(item, projectTypes: $0)
        } == true
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

  private static func countPresentations(
    _ totals: [TaskBoardWorkflowStatus: Int]
  ) -> [TaskBoardWorkflowCountPresentation] {
    TaskBoardWorkflowStatus.allCases.compactMap { status in
      guard let count = totals[status], count >= 1 else { return nil }
      return TaskBoardWorkflowCountPresentation(status: status, count: count)
    }
  }

  private static func routesToLocalHost(
    _ item: TaskBoardItem,
    projectTypes: [String]
  ) -> Bool {
    TaskBoardHostMachine.acceptsAny(
      machineProjectTypes: projectTypes,
      itemTargetProjectTypes: item.targetProjectTypes
    )
  }

  private static func summarySource(
    status: TaskBoardOrchestratorStatus,
    latestEvaluation: TaskBoardEvaluationSummary?,
    latestEvaluationBaselineRunID: String?,
    scopedItemIDs: Set<String>?
  ) -> SummarySource? {
    if let latestEvaluation, status.lastRun?.runId == latestEvaluationBaselineRunID {
      return .standaloneEvaluation(
        evaluationPresentation(latestEvaluation, scopedItemIDs: scopedItemIDs)
      )
    }
    guard let lastRun = status.lastRun else { return nil }
    return .lastRun(
      lastRun,
      appliedCount: appliedItemCount(for: lastRun, scopedItemIDs: scopedItemIDs),
      evaluation: lastRun.evaluation.map {
        evaluationPresentation($0, scopedItemIDs: scopedItemIDs)
      }
    )
  }

  static func appliedItemCount(for run: TaskBoardOrchestratorRunSummary) -> Int {
    appliedItemCount(for: run, scopedItemIDs: nil)
  }

  private static func appliedItemCount(
    for run: TaskBoardOrchestratorRunSummary,
    scopedItemIDs: Set<String>?
  ) -> Int {
    if let scopedItemIDs {
      var itemIDs = Set(
        (run.dispatch?.applied ?? [])
          .filter { scopedItemIDs.contains($0.boardItemId) }
          .map(\.boardItemId)
      )
      itemIDs.formUnion(
        run.evaluation?.records
          .filter { $0.updated && scopedItemIDs.contains($0.boardItemId) }
          .map(\.boardItemId) ?? []
      )
      return itemIDs.count
    }

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

  private static func evaluationPresentation(
    _ evaluation: TaskBoardEvaluationSummary,
    scopedItemIDs: Set<String>?
  ) -> TaskBoardEvaluationPillPresentation {
    guard let scopedItemIDs else {
      return TaskBoardEvaluationPillPresentation(
        total: evaluation.total,
        evaluated: evaluation.evaluated,
        updated: evaluation.updated,
        blocked: evaluation.blocked,
        failed: evaluation.failed
      )
    }
    return TaskBoardEvaluationPillPresentation.summarizing(
      evaluation.records.lazy
        .filter { scopedItemIDs.contains($0.boardItemId) }
        .map { ($0.outcome, $0.updated) }
    )
  }

  private static func evaluationPresentation(
    _ evaluation: TaskBoardOrchestratorEvaluationOutcome,
    scopedItemIDs: Set<String>?
  ) -> TaskBoardEvaluationPillPresentation {
    guard let scopedItemIDs else {
      return TaskBoardEvaluationPillPresentation(
        total: evaluation.total,
        evaluated: evaluation.evaluated,
        updated: evaluation.updated,
        blocked: evaluation.blocked,
        failed: evaluation.failed
      )
    }
    return TaskBoardEvaluationPillPresentation.summarizing(
      evaluation.records.lazy
        .filter { scopedItemIDs.contains($0.boardItemId) }
        .map { ($0.outcome, $0.updated) }
    )
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

struct TaskBoardEvaluationPillPresentation: Equatable, Sendable {
  let total: Int
  let evaluated: Int
  let updated: Int
  let blocked: Int
  let failed: Int

  static func summarizing<S: Sequence>(
    _ records: S
  ) -> Self where S.Element == (TaskBoardEvaluationOutcome, Bool) {
    var total = 0
    var evaluated = 0
    var updated = 0
    var blocked = 0
    var failed = 0
    for (outcome, didUpdate) in records {
      total += 1
      if didUpdate {
        updated += 1
      }
      switch outcome {
      case .skippedUnlinked:
        break
      case .missingSession, .missingTask:
        evaluated += 1
        failed += 1
      case .workerPending, .workerRunning, .reviewPending, .reviewRunning,
        .reviewChangesRequested, .completed:
        evaluated += 1
      case .blocked:
        evaluated += 1
        blocked += 1
      }
    }
    return Self(
      total: total,
      evaluated: evaluated,
      updated: updated,
      blocked: blocked,
      failed: failed
    )
  }
}

struct TaskBoardWorkflowCountPresentation: Identifiable, Equatable, Sendable {
  let status: TaskBoardWorkflowStatus
  let count: Int

  var id: String { status.rawValue }
}
