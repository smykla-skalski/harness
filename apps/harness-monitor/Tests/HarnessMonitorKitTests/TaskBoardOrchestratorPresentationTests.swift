import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Task-board orchestrator presentation")
struct TaskBoardOrchestratorPresentationTests {
  @Test("Applied count de-duplicates a board item updated by dispatch and evaluation")
  func appliedCountUsesUniqueBoardItemIDs() {
    let item = taskBoardItem(id: "board-1", status: .inProgress)
    let dispatch = TaskBoardDispatchSummary(
      plans: [],
      applied: [
        TaskBoardDispatchAppliedTask(
          boardItemId: item.id,
          sessionId: "sess-1",
          workItemId: "task-1",
          item: item
        )
      ]
    )
    let evaluation = TaskBoardEvaluationSummary(
      total: 1,
      evaluated: 1,
      updated: 1,
      records: [
        TaskBoardEvaluationRecord(
          boardItemId: item.id,
          outcome: .workerRunning,
          updated: true,
          item: item
        )
      ]
    )

    let run = orchestratorRun(dispatch: dispatch, evaluation: evaluation)

    #expect(TaskBoardOrchestratorPresentation.appliedItemCount(for: run) == 1)
  }

  @Test("Step mode exposes manual steps without starting autonomous scheduling")
  func stepModeExposesManualStepsWhileOrchestratorIsDisabled() {
    let disabledStepMode = orchestratorStatus(enabled: false, stepMode: true)

    #expect(
      TaskBoardOrchestratorPresentation.showsManualSteps(
        for: disabledStepMode,
        scopeSessionID: nil,
        hasStore: true
      )
    )
    #expect(
      TaskBoardOrchestratorPresentation.stateTitle(for: disabledStepMode)
        == "Paused (Step Mode)"
    )
  }

  @Test("Manual steps stay dashboard-only and require live step mode state")
  func manualStepsRespectDashboardScopeAndStoreAvailability() {
    let stepMode = orchestratorStatus(enabled: true, stepMode: true)
    let automaticMode = orchestratorStatus(enabled: true, stepMode: false)

    #expect(
      !TaskBoardOrchestratorPresentation.showsManualSteps(
        for: automaticMode,
        scopeSessionID: nil,
        hasStore: true
      )
    )
    #expect(
      !TaskBoardOrchestratorPresentation.showsManualSteps(
        for: stepMode,
        scopeSessionID: "session-1",
        hasStore: true
      )
    )
    #expect(
      !TaskBoardOrchestratorPresentation.showsManualSteps(
        for: stepMode,
        scopeSessionID: nil,
        hasStore: false
      )
    )
  }

  @Test("Idle workflow count excludes completed board items with idle workflow state")
  func idleWorkflowCountExcludesCompletedItems() {
    let items = [
      taskBoardItem(id: "done-default", status: .done),
      taskBoardItem(id: "done-idle", status: .done, workflowStatus: .idle),
      taskBoardItem(id: "todo-idle", status: .todo),
      taskBoardItem(id: "todo-running", status: .todo, workflowStatus: .running),
    ]
    let status = orchestratorStatus(
      workflowCounts: [
        TaskBoardWorkflowExecutionCount(status: .idle, count: 3),
        TaskBoardWorkflowExecutionCount(status: .running, count: 1),
      ]
    )

    let counts = TaskBoardOrchestratorPresentation(
      status: status,
      taskBoardItems: items,
      localHostProjectTypes: []
    ).workflowCounts

    #expect(
      counts == [
        TaskBoardWorkflowCountPresentation(status: .idle, count: 1),
        TaskBoardWorkflowCountPresentation(status: .running, count: 1),
      ]
    )
  }

  @Test("Idle subtraction uses the daemon's local-host routing population")
  func idleWorkflowCountExcludesOnlyLocalCompletedItems() {
    let items = [
      taskBoardItem(
        id: "remote-done",
        status: .done,
        workflowStatus: .idle,
        targetProjectTypes: ["mobile"]
      ),
      taskBoardItem(
        id: "local-todo",
        status: .todo,
        workflowStatus: .idle,
        targetProjectTypes: ["web"]
      ),
    ]
    let status = orchestratorStatus(
      workflowCounts: [TaskBoardWorkflowExecutionCount(status: .idle, count: 1)]
    )

    let counts = TaskBoardOrchestratorPresentation(
      status: status,
      taskBoardItems: items,
      localHostProjectTypes: ["web"]
    ).workflowCounts

    #expect(counts == [TaskBoardWorkflowCountPresentation(status: .idle, count: 1)])
  }

  @Test("Local-host routing failure hides Idle until a successful empty load")
  @MainActor
  func localHostRoutingFailureHidesIdleUntilSuccessfulEmptyLoad() throws {
    let status = orchestratorStatus(
      workflowCounts: [TaskBoardWorkflowExecutionCount(status: .idle, count: 1)]
    )
    let state = TaskBoardLocalHostRoutingState()
    let failedGeneration = try #require(state.beginLoad())

    state.finishLoadFailure(generation: failedGeneration)

    #expect(state.projectTypes == nil)
    #expect(!state.isLoading)
    #expect(
      TaskBoardOrchestratorPresentation(
        status: status,
        taskBoardItems: [],
        localHostProjectTypes: state.projectTypes
      ).workflowCounts.isEmpty
    )

    let successfulGeneration = try #require(state.beginLoad())
    state.finishLoad(projectTypes: [], generation: successfulGeneration)

    #expect(state.projectTypes?.isEmpty == true)
    #expect(!state.isLoading)
    #expect(
      TaskBoardOrchestratorPresentation(
        status: status,
        taskBoardItems: [],
        localHostProjectTypes: state.projectTypes
      ).workflowCounts
        == [TaskBoardWorkflowCountPresentation(status: .idle, count: 1)]
    )
  }

  @Test("Failed stage follows the last durable stage present in the run")
  func failedStageUsesDurableRunStages() {
    let dispatch = TaskBoardDispatchSummary(plans: [], applied: [])
    let evaluation = TaskBoardEvaluationSummary(total: 1)

    #expect(
      TaskBoardOrchestratorPresentation.failedStage(
        for: orchestratorRun(status: .failed)
      ) == .dispatch
    )
    #expect(
      TaskBoardOrchestratorPresentation.failedStage(
        for: orchestratorRun(status: .failed, dispatch: dispatch)
      ) == .evaluation
    )
    #expect(
      TaskBoardOrchestratorPresentation.failedStage(
        for: orchestratorRun(status: .failed, dispatch: dispatch, evaluation: evaluation)
      ) == .automation
    )
  }

  @Test("Standalone evaluation is visible only while its baseline run remains current")
  func standaloneEvaluationUsesRunIDProvenance() {
    let lastRun = orchestratorRun(runID: "run-current")
    let standalone = TaskBoardEvaluationSummary(total: 2, evaluated: 2)
    let presentation = TaskBoardOrchestratorPresentation(
      status: orchestratorStatus(lastRun: lastRun),
      taskBoardItems: []
    )

    let currentSource = presentation.summarySource(
      latestEvaluation: standalone,
      baselineRunID: "run-current"
    )
    guard case .standaloneEvaluation(let visibleEvaluation) = currentSource else {
      Issue.record("Expected the standalone evaluation for the current baseline run")
      return
    }
    #expect(visibleEvaluation == standalone)

    let supersedingSource = presentation.summarySource(
      latestEvaluation: standalone,
      baselineRunID: "run-previous"
    )
    guard case .lastRun(let visibleRun) = supersedingSource else {
      Issue.record("Expected a changed run ID to supersede the standalone evaluation")
      return
    }
    #expect(visibleRun.runId == "run-current")
  }

  @Test("Evaluation pins the refreshed run when status was initially unavailable")
  @MainActor
  func evaluationPinsRefreshedRunAfterNilStatus() async throws {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)
    store.globalTaskBoardOrchestratorStatus = nil

    #expect(await store.evaluateTaskBoard())

    let dashboard = store.contentUI.dashboard
    let refreshedStatus = try #require(dashboard.taskBoardOrchestratorStatus)
    let refreshedRunID = try #require(refreshedStatus.lastRun?.runId)
    let evaluation = try #require(dashboard.taskBoardEvaluationSummary)
    let baselineRunID = try #require(dashboard.taskBoardEvaluationBaselineRunID)
    #expect(refreshedRunID == "run-1")
    #expect(baselineRunID == refreshedRunID)

    let refreshedSource = TaskBoardOrchestratorPresentation(
      status: refreshedStatus,
      taskBoardItems: []
    ).summarySource(latestEvaluation: evaluation, baselineRunID: baselineRunID)
    guard case .standaloneEvaluation(let visibleEvaluation) = refreshedSource else {
      Issue.record("Expected the evaluation to remain visible after the initial status refresh")
      return
    }
    #expect(visibleEvaluation == evaluation)

    let laterSource = TaskBoardOrchestratorPresentation(
      status: orchestratorStatus(lastRun: orchestratorRun(runID: "run-2")),
      taskBoardItems: []
    ).summarySource(latestEvaluation: evaluation, baselineRunID: baselineRunID)
    guard case .lastRun(let visibleRun) = laterSource else {
      Issue.record("Expected a later orchestrator run to supersede the evaluation")
      return
    }
    #expect(visibleRun.runId == "run-2")
  }

  private func orchestratorStatus(
    enabled: Bool = true,
    running: Bool = false,
    stepMode: Bool = false,
    lastRun: TaskBoardOrchestratorRunSummary? = nil,
    workflowCounts: [TaskBoardWorkflowExecutionCount] = []
  ) -> TaskBoardOrchestratorStatus {
    TaskBoardOrchestratorStatus(
      enabled: enabled,
      running: running,
      stepMode: stepMode,
      lastRun: lastRun,
      workflowExecutionCounts: workflowCounts,
      settings: TaskBoardOrchestratorSettings(stepMode: stepMode, policyVersion: "v1")
    )
  }

  private func orchestratorRun(
    runID: String = "run-1",
    status: TaskBoardOrchestratorRunStatus = .completed,
    dispatch: TaskBoardDispatchSummary? = nil,
    evaluation: TaskBoardEvaluationSummary? = nil
  ) -> TaskBoardOrchestratorRunSummary {
    TaskBoardOrchestratorRunSummary(
      runId: runID,
      startedAt: "2026-07-14T10:00:00Z",
      completedAt: "2026-07-14T10:01:00Z",
      status: status,
      dryRun: false,
      sync: TaskBoardSyncSummary(total: 1, providers: []),
      audit: TaskBoardAuditSummary(total: 1, ready: 1, blocked: 0, deleted: 0, byStatus: []),
      dispatch: dispatch,
      evaluation: evaluation,
      error: status == .failed ? "stage failed" : nil,
      policyTraceIds: ["trace-1"]
    )
  }

  private func taskBoardItem(
    id: String,
    status: TaskBoardStatus,
    workflowStatus: TaskBoardWorkflowStatus? = nil,
    targetProjectTypes: [String] = []
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item \(id)",
      body: "Body",
      status: status,
      priority: .medium,
      tags: [],
      projectId: "project-1",
      targetProjectTypes: targetProjectTypes,
      agentMode: .interactive,
      externalRefs: [],
      planning: TaskBoardPlanningState(summary: "Approved plan"),
      workflow: workflowStatus.map { TaskBoardWorkflowState(status: $0) },
      sessionId: nil,
      workItemId: nil,
      usage: TaskBoardUsage(),
      createdAt: "2026-07-14T10:00:00Z",
      updatedAt: "2026-07-14T10:01:00Z",
      deletedAt: nil
    )
  }
}
