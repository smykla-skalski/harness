import Foundation

extension PreviewHarnessClient {
  public func taskBoardItems(status: TaskBoardStatus?) async throws -> [TaskBoardItem] {
    try await performActionDelay()
    return await state.currentTaskBoardItems(status: status)
  }

  public func taskBoardItem(id: String) async throws -> TaskBoardItem {
    try await performActionDelay()
    return try await state.currentTaskBoardItem(id: id)
  }

  public func createTaskBoardItem(
    request: TaskBoardCreateItemRequest
  ) async throws -> TaskBoardItem {
    try await performActionDelay()
    return await state.createTaskBoardItem(request: request)
  }

  public func updateTaskBoardItem(
    id: String,
    request: TaskBoardUpdateItemRequest
  ) async throws -> TaskBoardItem {
    try await performActionDelay()
    return try await state.updateTaskBoardItem(id: id, request: request)
  }

  public func deleteTaskBoardItem(id: String) async throws -> TaskBoardItem {
    try await performActionDelay()
    return try await state.deleteTaskBoardItem(id: id)
  }

  public func beginTaskBoardPlan(id: String) async throws -> TaskBoardPlanningResponse {
    try await performActionDelay()
    return try await state.beginTaskBoardPlan(id: id)
  }

  public func submitTaskBoardPlan(
    id: String,
    request: TaskBoardPlanSubmitRequest
  ) async throws -> TaskBoardPlanningResponse {
    try await performActionDelay()
    return try await state.submitTaskBoardPlan(id: id, request: request)
  }

  public func approveTaskBoardPlan(
    id: String,
    request: TaskBoardPlanApproveRequest
  ) async throws -> TaskBoardPlanningResponse {
    try await performActionDelay()
    return try await state.approveTaskBoardPlan(id: id, request: request)
  }

  public func revokeTaskBoardPlan(
    id: String,
    request: TaskBoardPlanRevokeRequest
  ) async throws -> TaskBoardPlanningResponse {
    try await performActionDelay()
    return try await state.revokeTaskBoardPlan(id: id, request: request)
  }

  public func syncTaskBoard(request _: TaskBoardSyncRequest) async throws -> TaskBoardSyncSummary {
    try await performActionDelay()
    return await state.syncTaskBoard()
  }

  public func dispatchTaskBoard(
    request: TaskBoardDispatchRequest
  ) async throws -> TaskBoardDispatchSummary {
    try await performActionDelay()
    return await state.dispatchTaskBoard(request: request)
  }

  public func auditTaskBoard(status: TaskBoardStatus?) async throws -> TaskBoardAuditSummary {
    try await performActionDelay()
    return await state.auditTaskBoard(status: status)
  }

  public func taskBoardProjects(status: TaskBoardStatus?) async throws -> [TaskBoardProjectSummary]
  {
    try await performActionDelay()
    return await state.taskBoardProjects(status: status)
  }

  public func taskBoardMachines(status: TaskBoardStatus?) async throws -> [TaskBoardMachineSummary]
  {
    try await performActionDelay()
    return await state.taskBoardMachines(status: status)
  }

  public func taskBoardHostLocal() async throws -> TaskBoardHostMachine {
    try await performActionDelay()
    return await state.taskBoardHostLocal()
  }

  public func taskBoardHostList() async throws -> [TaskBoardHostMachine] {
    try await performActionDelay()
    return await state.taskBoardHostList()
  }

  public func setTaskBoardHostProjectTypes(
    request: TaskBoardHostSetProjectTypesRequest
  ) async throws -> TaskBoardHostMachine {
    try await performActionDelay()
    return await state.setTaskBoardHostProjectTypes(request: request)
  }

  public func evaluateTaskBoard(
    request: TaskBoardEvaluateRequest
  ) async throws -> TaskBoardEvaluationSummary {
    try await performActionDelay()
    return await state.evaluateTaskBoard(request: request)
  }

  public func taskBoardOrchestratorStatus() async throws -> TaskBoardOrchestratorStatus {
    try await performActionDelay()
    return await state.currentTaskBoardOrchestratorStatus()
  }

  public func startTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    try await performActionDelay()
    return await state.setTaskBoardOrchestratorRunning(true)
  }

  public func stopTaskBoardOrchestrator() async throws -> TaskBoardOrchestratorStatus {
    try await performActionDelay()
    return await state.setTaskBoardOrchestratorRunning(false)
  }

  public func runTaskBoardOrchestratorOnce(
    request: TaskBoardOrchestratorRunOnceRequest
  ) async throws -> TaskBoardOrchestratorRunOnceResponse {
    try await performActionDelay()
    return await state.runTaskBoardOrchestratorOnce(request: request)
  }
}

extension TaskBoardStatus {
  var previewTaskStatus: TaskStatus? {
    switch self {
    case .new, .planning, .planReview, .needsYou, .todo:
      .open
    case .inProgress:
      .inProgress
    case .inReview:
      .awaitingReview
    case .done:
      .done
    case .blocked:
      .blocked
    case .unknown:
      nil
    }
  }

  var previewEvaluationStatus: TaskBoardStatus {
    switch self {
    case .inProgress:
      .inReview
    case .inReview:
      .done
    default:
      self
    }
  }

  var previewEvaluationWorkflowStatus: TaskBoardWorkflowStatus {
    switch previewEvaluationStatus {
    case .done:
      .completed
    case .blocked:
      .failed
    case .inProgress, .inReview:
      .running
    default:
      .idle
    }
  }

  var previewEvaluationOutcome: TaskBoardEvaluationOutcome {
    switch self {
    case .done:
      .completed
    case .blocked:
      .blocked
    case .inReview:
      .reviewPending
    case .inProgress:
      .workerRunning
    default:
      .workerPending
    }
  }
}

extension TaskBoardDispatchPlan {
  static func previewPlan(for item: TaskBoardItem) -> TaskBoardDispatchPlan {
    TaskBoardDispatchPlan(
      boardItemId: item.id,
      readiness: TaskBoardDispatchReadiness(state: "ready", reason: nil),
      session: TaskBoardSessionIntent(
        kind: item.sessionId == nil ? "create" : "existing",
        sessionId: item.sessionId,
        title: item.title,
        context: item.body,
        projectId: item.projectId
      ),
      task: TaskBoardTaskCreationIntent(
        title: item.title,
        context: item.body,
        severity: .medium,
        suggestedFix: item.planning.summary,
        source: .manual,
        tags: item.tags,
        externalRefs: item.externalRefs
      ),
      worker: TaskBoardWorkerIntent(mode: item.agentMode),
      reviewer: TaskBoardReviewerIntent(
        phase: "review",
        suggestedPersona: "reviewer",
        requiredConsensus: 1
      ),
      evaluator: TaskBoardEvaluatorIntent(phase: "evaluate", mode: .evaluate),
      policy: PolicySimulationDecision(
        decision: "allow",
        reasonCode: "preview_allow",
        policyVersion: "preview"
      )
    )
  }
}

extension TaskBoardEvaluationSummary {
  static func previewSummary(
    records: [TaskBoardEvaluationRecord]
  ) -> TaskBoardEvaluationSummary {
    TaskBoardEvaluationSummary(
      total: records.count,
      evaluated: records.count,
      updated: records.count { $0.updated },
      skipped: records.count { $0.outcome == .skippedUnlinked },
      completed: records.count { $0.outcome == .completed },
      running: records.count { $0.outcome == .workerRunning },
      reviewing: records.count { $0.outcome == .reviewPending },
      blocked: records.count { $0.outcome == .blocked },
      records: records
    )
  }
}

extension TaskBoardOrchestratorStatus {
  func replacingPreviewRuntime(running: Bool) -> TaskBoardOrchestratorStatus {
    TaskBoardOrchestratorStatus(
      enabled: true,
      running: running,
      currentTick: running
        ? TaskBoardOrchestratorTickInfo(
          runId: "preview-running",
          phase: .dispatch,
          startedAt: PreviewHarnessClientState.mutationTimestamp,
          dryRun: settings.dryRunDefault
        )
        : nil,
      lastRun: lastRun,
      workflowExecutionCounts: workflowExecutionCounts,
      settings: settings
    )
  }

  func replacingPreviewRun(
    run: TaskBoardOrchestratorRunSummary
  ) -> TaskBoardOrchestratorStatus {
    TaskBoardOrchestratorStatus(
      enabled: true,
      running: false,
      currentTick: nil,
      lastRun: run,
      workflowExecutionCounts: [
        TaskBoardWorkflowExecutionCount(status: .completed, count: 1)
      ],
      settings: settings
    )
  }
}

extension TaskBoardOrchestratorRunSummary {
  static func previewRun(
    dryRun: Bool,
    sync: TaskBoardSyncSummary,
    dispatch: TaskBoardDispatchSummary,
    evaluation: TaskBoardEvaluationSummary
  ) -> TaskBoardOrchestratorRunSummary {
    TaskBoardOrchestratorRunSummary(
      runId: "preview-run",
      startedAt: PreviewHarnessClientState.mutationTimestamp,
      completedAt: PreviewHarnessClientState.mutationTimestamp,
      status: .completed,
      dryRun: dryRun,
      sync: sync,
      audit: TaskBoardAuditSummary(
        total: sync.total,
        ready: dispatch.plans.count,
        blocked: 0,
        deleted: 0,
        byStatus: []
      ),
      dispatch: dispatch,
      evaluation: evaluation,
      policyTraceIds: ["preview-policy"]
    )
  }
}
