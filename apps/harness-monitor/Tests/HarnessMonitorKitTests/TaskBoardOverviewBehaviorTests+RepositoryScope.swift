import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

extension TaskBoardOverviewBehaviorTests {
  @Test("Configured repositories exclude cached disabled-repository cards and totals")
  func configuredRepositoriesExcludeCachedDisabledRepositoryCardsAndTotals() async {
    let enabled = taskBoardItem(
      id: "enabled",
      status: .todo,
      projectId: nil,
      executionRepository: "SMYKLA-SKALSKI/HARNESS"
    )
    let disabledOpen = taskBoardItem(
      id: "disabled-open",
      status: .failed,
      projectId: nil,
      executionRepository: "example/disabled"
    )
    let disabledDone = taskBoardItem(
      id: "disabled-done",
      status: .done,
      projectId: nil,
      executionRepository: "example/disabled"
    )
    let status = TaskBoardOrchestratorStatus(
      enabled: false,
      running: false,
      workflowExecutionCounts: [
        TaskBoardWorkflowExecutionCount(status: .idle, count: 996),
        TaskBoardWorkflowExecutionCount(status: .paused, count: 2),
      ],
      settings: TaskBoardOrchestratorSettings(policyVersion: "repository-scope-test")
    )

    let presentation = await TaskBoardOverviewPresentationWorker().compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [enabled, disabledOpen, disabledDone],
        decisionItems: [],
        scopeSessionID: nil,
        configuredRepositories: ["smykla-skalski/harness"],
        orchestratorStatus: status,
        localHostProjectTypes: [],
        taskBoardProjects: []
      )
    )

    #expect(presentation.taskBoardItems.map(\.id) == ["enabled"])
    #expect(presentation.aggregateOpenCount == 1)
    #expect(presentation.aggregateBlockedCount == 0)
    #expect(presentation.aggregateDoneCount == 0)
    #expect(
      presentation.orchestratorPresentation?.workflowCounts
        == [TaskBoardWorkflowCountPresentation(status: .idle, count: 1)]
    )
  }

  @Test("Volatile orchestrator updates reuse the configured board projection")
  func volatileOrchestratorUpdatesReuseConfiguredBoardProjection() async {
    let worker = TaskBoardOverviewPresentationWorker()
    let item = taskBoardItem(
      id: "enabled",
      status: .todo,
      projectId: nil,
      executionRepository: "example/enabled"
    )
    let initialStatus = TaskBoardOrchestratorStatus(
      enabled: true,
      running: false,
      settings: TaskBoardOrchestratorSettings(policyVersion: "repository-scope-test")
    )
    let updatedStatus = TaskBoardOrchestratorStatus(
      enabled: true,
      running: true,
      settings: TaskBoardOrchestratorSettings(policyVersion: "repository-scope-test")
    )
    let initialInput = TaskBoardOverviewPresentationInput(
      snapshot: TaskBoardInboxSnapshot(),
      taskBoardItems: [item],
      decisionItems: [],
      scopeSessionID: nil,
      configuredRepositories: ["example/enabled"],
      orchestratorStatus: initialStatus,
      localHostProjectTypes: [],
      taskBoardProjects: []
    )

    _ = await worker.compute(input: initialInput)
    let updated = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: initialInput.snapshot,
        taskBoardItems: initialInput.taskBoardItems,
        decisionItems: initialInput.decisionItems,
        scopeSessionID: initialInput.scopeSessionID,
        configuredRepositories: initialInput.configuredRepositories,
        orchestratorStatus: updatedStatus,
        localHostProjectTypes: initialInput.localHostProjectTypes,
        taskBoardProjects: initialInput.taskBoardProjects
      )
    )

    #expect(await worker.boardRebuildCountForTesting() == 1)
    #expect(updated.taskBoardItems.map(\.id) == [item.id])
    #expect(updated.orchestratorPresentation != nil)
  }

  @Test("Unavailable board snapshots preserve the daemon evaluation summary")
  func unavailableBoardSnapshotsPreserveDaemonEvaluationSummary() async {
    let evaluation = TaskBoardOrchestratorEvaluationOutcome(
      total: 1,
      evaluated: 1,
      records: [
        TaskBoardOrchestratorEvaluationRecord(
          boardItemId: "not-loaded",
          outcome: .completed
        )
      ]
    )
    let run = TaskBoardOrchestratorRunSummary(
      runId: "run-1",
      startedAt: "2026-07-14T10:00:00Z",
      completedAt: "2026-07-14T10:01:00Z",
      status: .completed,
      dryRun: true,
      sync: TaskBoardSyncSummary(total: 0, providers: []),
      audit: TaskBoardAuditSummary(total: 0, ready: 0, blocked: 0, deleted: 0, byStatus: []),
      dispatch: nil,
      evaluation: evaluation,
      error: nil,
      policyTraceIds: []
    )
    let status = TaskBoardOrchestratorStatus(
      enabled: true,
      running: false,
      lastRun: run,
      settings: TaskBoardOrchestratorSettings(policyVersion: "repository-scope-test")
    )

    let presentation = await TaskBoardOverviewPresentationWorker().compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [],
        decisionItems: [],
        scopeSessionID: nil,
        configuredRepositories: ["example/enabled"],
        taskBoardItemsSnapshotAvailable: false,
        orchestratorStatus: status,
        localHostProjectTypes: [],
        taskBoardProjects: []
      )
    )

    guard
      case .lastRun(_, _, let scopedEvaluation) = presentation.orchestratorPresentation?
        .summarySource
    else {
      Issue.record("Expected the daemon last-run evaluation")
      return
    }
    #expect(scopedEvaluation?.total == 1)
    #expect(scopedEvaluation?.evaluated == 1)
  }

  @Test("Changing configured repositories invalidates the cached presentation")
  func changingConfiguredRepositoriesInvalidatesCachedPresentation() async {
    let worker = TaskBoardOverviewPresentationWorker()
    let first = taskBoardItem(
      id: "first",
      status: .todo,
      projectId: nil,
      executionRepository: "example/first"
    )
    let second = taskBoardItem(
      id: "second",
      status: .todo,
      projectId: nil,
      executionRepository: "example/second"
    )
    let input = TaskBoardOverviewPresentationInput(
      snapshot: TaskBoardInboxSnapshot(),
      taskBoardItems: [first, second],
      decisionItems: [],
      scopeSessionID: nil,
      configuredRepositories: ["example/first", "example/second"],
      taskBoardProjects: []
    )
    _ = await worker.compute(input: input)

    let narrowed = await worker.compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: input.snapshot,
        taskBoardItems: input.taskBoardItems,
        decisionItems: input.decisionItems,
        scopeSessionID: input.scopeSessionID,
        configuredRepositories: ["example/first"],
        taskBoardProjects: input.taskBoardProjects
      )
    )

    #expect(narrowed.taskBoardItems.map(\.id) == ["first"])
    #expect(narrowed.aggregateOpenCount == 1)
  }

  @Test("Configured repositories scope registered GitHub projects but preserve local work")
  func configuredRepositoriesScopeRegisteredGitHubProjectsButPreserveLocalWork() async {
    let enabledProject = TaskBoardProjectSummary(
      projectId: "project-enabled",
      source: .gitHub,
      slug: "example/enabled",
      itemCount: 1,
      readyCount: 1
    )
    let disabledProject = TaskBoardProjectSummary(
      projectId: "project-disabled",
      source: .gitHub,
      slug: "example/disabled",
      itemCount: 1,
      readyCount: 1
    )
    let manualProject = TaskBoardProjectSummary(
      projectId: "project-manual",
      source: .manual,
      slug: "local-work",
      itemCount: 1,
      readyCount: 1
    )
    let enabled = taskBoardItem(
      id: "enabled-project-item",
      status: .todo,
      projectId: nil,
      sourceProjectId: enabledProject.projectId
    )
    let disabled = taskBoardItem(
      id: "disabled-project-item",
      status: .todo,
      projectId: nil,
      sourceProjectId: disabledProject.projectId
    )
    let local = taskBoardItem(
      id: "local-item",
      status: .todo,
      projectId: nil
    )
    let manual = taskBoardItem(
      id: "manual-project-item",
      status: .todo,
      projectId: "workspace/manual",
      sourceProjectId: manualProject.projectId
    )

    let presentation = await TaskBoardOverviewPresentationWorker().compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [enabled, disabled, local, manual],
        decisionItems: [],
        scopeSessionID: nil,
        configuredRepositories: [enabledProject.slug],
        taskBoardProjects: [enabledProject, disabledProject, manualProject]
      )
    )

    #expect(presentation.taskBoardItems.map(\.id) == [enabled.id, local.id, manual.id])
    #expect(presentation.aggregateOpenCount == 3)
  }

  @Test("Cached GitHub references stay scoped after disabled projects leave the catalog")
  func cachedGitHubReferencesStayScopedWithoutDisabledProjectMetadata() async {
    let stale = taskBoardItem(
      id: "stale-disabled-project-item",
      status: .failed,
      projectId: nil,
      sourceProjectId: "project-no-longer-returned",
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/disabled#1387",
          url: "https://github.com/example/disabled/pull/1387"
        )
      ]
    )

    let presentation = await TaskBoardOverviewPresentationWorker().compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [stale],
        decisionItems: [],
        scopeSessionID: nil,
        configuredRepositories: ["smykla-skalski/harness"],
        taskBoardProjects: []
      )
    )

    #expect(presentation.taskBoardItems.isEmpty)
    #expect(presentation.aggregateOpenCount == 0)
    #expect(presentation.aggregateBlockedCount == 0)
  }

  @Test("An unavailable repository scope preserves cached work until settings load")
  func unavailableRepositoryScopePreservesCachedWorkUntilSettingsLoad() async {
    let cached = taskBoardItem(
      id: "cached",
      status: .todo,
      projectId: nil,
      executionRepository: "example/previously-enabled"
    )

    let presentation = await TaskBoardOverviewPresentationWorker().compute(
      input: TaskBoardOverviewPresentationInput(
        snapshot: TaskBoardInboxSnapshot(),
        taskBoardItems: [cached],
        decisionItems: [],
        scopeSessionID: nil,
        configuredRepositories: nil,
        taskBoardProjects: []
      )
    )

    #expect(presentation.taskBoardItems.map(\.id) == [cached.id])
    #expect(presentation.aggregateOpenCount == 1)
  }
}
