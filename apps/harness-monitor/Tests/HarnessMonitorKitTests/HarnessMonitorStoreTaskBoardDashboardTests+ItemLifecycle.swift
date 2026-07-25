import Foundation
import Testing

@testable import HarnessMonitorKit

@MainActor
extension HarnessMonitorStoreTaskBoardDashboardTests {
  @Test("Create task board item saves the draft in the chosen lane in one call")
  func createTaskBoardItemSavesDraftAndAppliesStatus() async {
    let client = RecordingHarnessClient()
    let store = await makeBootstrappedStore(client: client)

    let success = await store.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "New board item",
        body: "Body",
        status: .agenticReview,
        priority: .critical,
        agentMode: .planning,
        tags: ["monitor"],
        projectId: "project-1",
        planning: TaskBoardPlanningState(summary: "Plan first")
      )
    )

    #expect(success)
    #expect(
      client.recordedCalls().contains(
        .createTaskBoardItem(
          title: "New board item",
          priority: .critical,
          status: .agenticReview
        )
      )
    )
    #expect(
      client.recordedCalls().contains {
        if case .updateTaskBoardItem = $0 { return true }
        return false
      } == false,
      "the chosen lane must not cost a follow-up update"
    )
    #expect(store.globalTaskBoardItems.first?.title == "New board item")
    #expect(store.globalTaskBoardItems.first?.status == .agenticReview)
    #expect(store.currentSuccessFeedbackMessage == "Created task board item")
  }

  @Test("A failed create reports failure and caches nothing")
  func failedCreateCachesNothing() async {
    let client = RecordingHarnessClient()
    client.configureTaskBoardCreateError(
      HarnessMonitorAPIError.server(code: 503, message: "Task board unavailable.")
    )
    let store = await makeBootstrappedStore(client: client)

    let success = await store.createTaskBoardItem(
      request: TaskBoardCreateItemRequest(
        title: "New board item",
        body: "Body",
        status: .agenticReview,
        priority: .high,
        agentMode: .planning,
        tags: ["monitor"],
        projectId: "project-1",
        planning: TaskBoardPlanningState(summary: "Plan first")
      )
    )

    #expect(success == false)
    #expect(store.globalTaskBoardItems.isEmpty)
    #expect(store.currentFailureFeedbackMessage != nil)
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
        status: .failed,
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
    #expect(item?.status == .failed)
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

  func sampleTaskBoardItem(
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
