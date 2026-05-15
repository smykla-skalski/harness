import Testing

@testable import HarnessMonitorKit

@MainActor
@Suite("Harness Monitor task-board dashboard")
struct HarnessMonitorStoreTaskBoardDashboardTests {
  @Test("Refresh task board dashboard imports external items with applied pull sync")
  func refreshTaskBoardDashboardImportsExternalItemsWithAppliedPullSync() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([])
    client.configureTaskBoardSync(
      summary: TaskBoardSyncSummary(
        total: 1,
        providers: [],
        operations: [
          TaskBoardExternalSyncOperation(
            provider: .gitHub,
            action: .pull,
            boardItemId: "board-1",
            externalId: "123",
            url: "https://example.invalid/issues/123",
            dryRun: false,
            applied: true
          )
        ]
      ),
      importedItems: [sampleTaskBoardItem()]
    )
    let store = await makeBootstrappedStore(client: client)
    let baselineCalls = client.readCallCount(.taskBoardItems(nil))

    await store.refreshTaskBoardDashboard()

    #expect(
      client.recordedCalls().contains(
        .syncTaskBoard(direction: .pull, dryRun: false, status: nil, provider: nil)
      )
    )
    #expect(client.readCallCount(.taskBoardItems(nil)) == baselineCalls + 1)
    #expect(store.globalTaskBoardItems.first?.id == "board-1")
    #expect(store.globalTaskBoardItems.first?.externalRefs.first?.provider == .gitHub)
    #expect(store.globalTaskBoardSyncSummary?.operations.first?.boardItemId == "board-1")
    #expect(store.contentUI.dashboard.taskBoardItems.first?.id == "board-1")
    #expect(store.contentUI.dashboard.taskBoardSyncSummary?.total == 1)
  }

  @Test("Evaluate task board records the summary and refreshes dashboard state")
  func evaluateTaskBoardRecordsSummaryAndRefreshesDashboardState() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let success = await store.evaluateTaskBoard(status: .inProgress, dryRun: true)

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .evaluateTaskBoard(dryRun: true, status: .inProgress, itemID: nil)
      )
    )
    #expect(store.globalTaskBoardEvaluationSummary?.updated == 1)
    #expect(store.contentUI.dashboard.taskBoardEvaluationSummary?.updated == 1)
    #expect(store.currentSuccessFeedbackMessage == "Evaluated task board")
  }

  @Test("Evaluate task board can target one board item")
  func evaluateTaskBoardCanTargetOneBoardItem() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let success = await store.evaluateTaskBoard(
      status: .todo,
      itemID: "board-1",
      dryRun: false
    )

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .evaluateTaskBoard(dryRun: false, status: .todo, itemID: "board-1")
      )
    )
    #expect(store.globalTaskBoardEvaluationSummary?.records.first?.boardItemId == "board-1")
  }

  @Test("Dispatch task board can apply one board item and refresh dashboard state")
  func dispatchTaskBoardCanApplyOneBoardItemAndRefreshDashboardState() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.dispatchTaskBoard(
      request: TaskBoardDispatchRequest(itemId: "board-1", dryRun: false)
    )

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .dispatchTaskBoard(
          dryRun: false,
          status: nil,
          itemID: "board-1",
          projectDir: nil,
          actor: nil
        )
      )
    )
    #expect(store.globalTaskBoardDispatchSummary?.applied.map(\.boardItemId) == ["board-1"])
    #expect(store.contentUI.dashboard.taskBoardDispatchSummary?.applied.count == 1)
    #expect(store.globalTaskBoardItems.first?.status == .inProgress)
    #expect(store.currentSuccessFeedbackMessage == "Dispatched task board")
  }

  @Test("Audit, projects, and machines summaries update dashboard state")
  func auditProjectsAndMachinesUpdateDashboardState() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([
      sampleTaskBoardItem(id: "board-1", status: .todo, agentMode: .interactive, projectId: "project-1"),
      sampleTaskBoardItem(id: "board-2", status: .blocked, agentMode: .planning, projectId: "project-2"),
    ])
    let store = await makeBootstrappedStore(client: client)

    let audited = await store.auditTaskBoard()
    let loadedProjects = await store.refreshTaskBoardProjects()
    let loadedMachines = await store.refreshTaskBoardMachines()

    #expect(audited)
    #expect(loadedProjects)
    #expect(loadedMachines)
    #expect(client.recordedCalls().contains(.auditTaskBoard(status: nil)))
    #expect(client.recordedCalls().contains(.taskBoardProjects(status: nil)))
    #expect(client.recordedCalls().contains(.taskBoardMachines(status: nil)))
    #expect(store.globalTaskBoardItemAuditSummary?.total == 2)
    #expect(store.contentUI.dashboard.taskBoardItemAuditSummary?.blocked == 1)
    #expect(store.globalTaskBoardProjects?.count == 2)
    #expect(store.contentUI.dashboard.taskBoardProjects?.count == 2)
    #expect(store.globalTaskBoardMachines?.count == 2)
    #expect(store.contentUI.dashboard.taskBoardMachines?.count == 2)
  }

  @Test("Moving a task board item updates status through the daemon")
  func movingTaskBoardItemUpdatesStatusThroughDaemon() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.updateTaskBoardItemStatus(id: "board-1", status: .inProgress)

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .updateTaskBoardItem(id: "board-1", status: .inProgress)
      )
    )
    #expect(store.globalTaskBoardItems.first?.status == .inProgress)
    #expect(store.contentUI.dashboard.taskBoardItems.first?.status == .inProgress)
    #expect(store.currentSuccessFeedbackMessage == "Moved task board item")
  }

  @Test("Create task board item saves the draft and applies the chosen status")
  func createTaskBoardItemSavesDraftAndAppliesStatus() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let success = await store.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "New board item",
        body: "Body",
        priority: .critical,
        agentMode: .planning,
        tags: ["monitor"],
        projectId: "project-1",
        planning: TaskBoardPlanningState(summary: "Plan first")
      ),
      initialStatus: .planReview
    )

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .createTaskBoardItem(title: "New board item", priority: .critical)
      )
    )
    #expect(
      client.recordedCalls().contains(
        .updateTaskBoardItem(id: "board-1", status: .planReview)
      )
    )
    #expect(store.globalTaskBoardItems.first?.title == "New board item")
    #expect(store.globalTaskBoardItems.first?.status == .planReview)
    #expect(store.currentSuccessFeedbackMessage == "Created task board item")
  }

  @Test("Edit task board item saves full editor fields")
  func editTaskBoardItemSavesFullEditorFields() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.updateTaskBoardItem(
      id: "board-1",
      request: TaskBoardUpdateItemRequest(
        title: "Edited",
        body: "Updated body",
        status: .blocked,
        priority: .low,
        agentMode: .evaluate,
        tags: ["edited", "ui"],
        projectId: nil,
        clearProjectId: true,
        planning: TaskBoardPlanningState(summary: "Updated plan"),
        sessionId: nil,
        clearSessionId: true,
        workItemId: nil,
        clearWorkItemId: true
      )
    )

    #expect(success)
    let item = store.globalTaskBoardItems.first
    #expect(item?.title == "Edited")
    #expect(item?.body == "Updated body")
    #expect(item?.status == .blocked)
    #expect(item?.priority == .low)
    #expect(item?.agentMode == .evaluate)
    #expect(item?.tags == ["edited", "ui"])
    #expect(item?.projectId == nil)
    #expect(item?.sessionId == nil)
    #expect(item?.workItemId == nil)
    #expect(item?.planning.summary == "Updated plan")
    #expect(store.currentSuccessFeedbackMessage == "Saved task board item")
  }

  @Test("Delete task board item removes it from dashboard state")
  func deleteTaskBoardItemRemovesItFromDashboardState() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    let store = await makeBootstrappedStore(client: client)

    let success = await store.deleteTaskBoardItem(id: "board-1")

    #expect(success)
    #expect(client.recordedCalls().contains(.deleteTaskBoardItem(id: "board-1")))
    #expect(store.globalTaskBoardItems.isEmpty)
    #expect(store.contentUI.dashboard.taskBoardItems.isEmpty)
    #expect(store.currentSuccessFeedbackMessage == "Deleted task board item")
  }

  @Test("Planning lifecycle actions update task board item state")
  func planningLifecycleActionsUpdateTaskBoardItemState() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardItems([sampleTaskBoardItem()])
    let store = await makeBootstrappedStore(client: client)

    let began = await store.beginTaskBoardPlan(id: "board-1")
    let submitted = await store.submitTaskBoardPlan(id: "board-1", summary: "Use plan.")
    let approved = await store.approveTaskBoardPlan(
      id: "board-1",
      approvedBy: "lead",
      approvedAt: "2026-05-14T02:00:00Z"
    )

    #expect(began)
    #expect(submitted)
    #expect(approved)
    #expect(client.recordedCalls().contains(.beginTaskBoardPlan(id: "board-1")))
    #expect(
      client.recordedCalls().contains(
        .submitTaskBoardPlan(id: "board-1", summary: "Use plan.")
      )
    )
    #expect(
      client.recordedCalls().contains(
        .approveTaskBoardPlan(
          id: "board-1",
          approvedBy: "lead",
          approvedAt: "2026-05-14T02:00:00Z"
        )
      )
    )
    #expect(store.globalTaskBoardItems.first?.status == .todo)
    #expect(store.globalTaskBoardItems.first?.planning.summary == "Use plan.")
    #expect(store.globalTaskBoardItems.first?.planning.approvedBy == "lead")
    #expect(store.currentSuccessFeedbackMessage == "Approved task board plan")
  }

  @Test("Run once forwards scoped board request and refreshes dashboard status")
  func runOnceForwardsScopedBoardRequestAndRefreshesDashboardStatus() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let success = await store.runTaskBoardOrchestratorOnce(
      request: TaskBoardOrchestratorRunOnceRequest(
        dryRun: false,
        status: .todo,
        projectDir: "/tmp/harness"
      )
    )

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .runTaskBoardOrchestratorOnce(
          itemID: nil,
          dryRun: false,
          status: .todo,
          projectDir: "/tmp/harness"
        )
      )
    )
    #expect(store.globalTaskBoardOrchestratorStatus?.enabled == true)
    #expect(store.contentUI.dashboard.taskBoardOrchestratorStatus?.enabled == true)
    #expect(store.currentSuccessFeedbackMessage == "Ran task board")
  }

  @Test("Start and stop orchestrator update dashboard status")
  func startAndStopOrchestratorUpdateDashboardStatus() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let started = await store.startTaskBoardOrchestrator()
    let stopped = await store.stopTaskBoardOrchestrator()

    #expect(started)
    #expect(stopped)
    #expect(client.recordedCalls().contains(.startTaskBoardOrchestrator))
    #expect(client.recordedCalls().contains(.stopTaskBoardOrchestrator))
    #expect(store.globalTaskBoardOrchestratorStatus?.running == false)
    #expect(store.contentUI.dashboard.taskBoardOrchestratorStatus?.running == false)
    #expect(store.currentSuccessFeedbackMessage == "Stopped task board")
  }

  private func sampleTaskBoardItem(
    id: String = "board-1",
    status: TaskBoardStatus = .todo,
    agentMode: TaskBoardAgentMode = .interactive,
    projectId: String = "project-1"
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: id,
      title: "Board item",
      body: "Body",
      status: status,
      priority: .high,
      tags: ["automation"],
      projectId: projectId,
      agentMode: agentMode,
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "123",
          url: "https://example.invalid/issues/123"
        )
      ],
      planning: TaskBoardPlanningState(summary: "Approved plan"),
      workflow: nil,
      sessionId: "sess-1",
      workItemId: "task-1",
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }
}
