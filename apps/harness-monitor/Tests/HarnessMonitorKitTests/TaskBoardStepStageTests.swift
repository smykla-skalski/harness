import Foundation
import Testing

@testable import HarnessMonitorKit
@testable import HarnessMonitorUIPreviewable

@Suite("Step Mode stage resolver")
struct TaskBoardStepStageTests {
  @Test("No target when there is no worked item")
  func noTargetWhenNoItem() {
    let plan = TaskBoardStepStageResolver.plan(for: TaskBoardStepStageInputs(item: nil))

    #expect(plan.stage == .noTarget)
    #expect(plan.column == nil)
    #expect(plan.primaryAction == .sync)
    #expect(plan.inlineLinks.isEmpty)
  }

  @Test("Todo item that is not picked is ready to pick")
  func readyToPickWhenTodoNotPicked() {
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(item: item(status: .todo))
    )

    #expect(plan.stage == .readyToPick)
    #expect(plan.column == .todo)
    #expect(plan.primaryAction == .pick)
    #expect(plan.primaryAction?.needsConfirmation == false)
  }

  @Test("Picked Todo item is ready to deliver")
  func readyToDeliverWhenPicked() {
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(item: item(status: .todo), hasPicked: true)
    )

    #expect(plan.stage == .readyToDeliver)
    #expect(plan.column == .todo)
    #expect(plan.primaryAction == .deliver)
  }

  @Test("In Progress board maps to worker running with a watch link")
  func workerRunningWhenInProgress() {
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(
        item: item(status: .inProgress, workflow: TaskBoardWorkflowState(status: .running, currentStepId: "worker"))
      )
    )

    #expect(plan.stage == .workerRunning)
    #expect(plan.column == .inProgress)
    #expect(plan.primaryAction == .evaluate)
    #expect(plan.inlineLinks.contains(.watch))
  }

  @Test("A just-delivered item reads as worker running before the first evaluate")
  func workerRunningWhenDeliveredBeforeEvaluate() {
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(item: item(status: .todo), hasDelivered: true)
    )

    #expect(plan.stage == .workerRunning)
  }

  @Test("Awaiting-review task status wins over a stale In Progress board")
  func awaitingReviewFromTaskStatus() {
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(
        item: item(status: .inProgress),
        latestRecord: record(taskStatus: .awaitingReview, outcome: .reviewPending)
      )
    )

    #expect(plan.stage == .awaitingReview)
    #expect(plan.column == .toReview)
    #expect(plan.primaryAction == .evaluate)
    #expect(plan.inlineLinks.contains(.openTask))
  }

  @Test("In-review task status maps to the in-review stage")
  func inReviewFromTaskStatus() {
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(
        item: item(status: .inReview),
        latestRecord: record(taskStatus: .inReview, outcome: .reviewRunning)
      )
    )

    #expect(plan.stage == .inReview)
    #expect(plan.column == .inReview)
    #expect(plan.primaryAction == .evaluate)
  }

  @Test("Changes-requested outcome surfaces the reviewer reason and PR link")
  func changesRequestedFromOutcome() {
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(
        item: item(
          status: .inReview,
          workflow: TaskBoardWorkflowState(status: .running, prUrl: "https://example.com/pr/1")
        ),
        latestRecord: record(
          taskStatus: .inReview,
          outcome: .reviewChangesRequested,
          reason: "Fix the retry loop"
        )
      )
    )

    #expect(plan.stage == .changesRequested)
    #expect(plan.column == .inReview)
    #expect(plan.whatHappened?.contains("Fix the retry loop") == true)
    #expect(plan.inlineLinks.contains(.openPullRequest))
  }

  @Test("Blocked board status has no primary action and shows the reason")
  func blockedFromBoardStatus() {
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(
        item: item(
          status: .blocked,
          workflow: TaskBoardWorkflowState(status: .failed, lastError: "needs human decision")
        )
      )
    )

    #expect(plan.stage == .blocked)
    #expect(plan.primaryAction == nil)
    #expect(plan.whatHappened?.contains("needs human decision") == true)
  }

  @Test("Done board status is terminal with no primary action")
  func doneWhenBoardDone() {
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(item: item(status: .done))
    )

    #expect(plan.stage == .done)
    #expect(plan.column == .done)
    #expect(plan.primaryAction == nil)
  }

  @Test("Approved task with a board behind offers Complete to finalize")
  func doneNeedsCompleteWhenTaskDoneBoardBehind() {
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(
        item: item(status: .inReview),
        latestRecord: record(taskStatus: .done, outcome: .completed)
      )
    )

    #expect(plan.stage == .done)
    #expect(plan.primaryAction == .complete)
  }

  @Test("A live task status outranks a stale failed board")
  func taskStatusOutranksFailedBoard() {
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(
        item: item(status: .failed),
        latestRecord: record(taskStatus: .inReview, outcome: .reviewRunning)
      )
    )

    #expect(plan.stage == .inReview)
  }

  @Test("A GitHub-only item can still open its task link")
  func gitHubOnlyItemSurfacesOpenTaskLink() {
    let githubItem = item(
      status: .blocked,
      sessionId: nil,
      workItemId: nil,
      externalRefs: [
        TaskBoardExternalRef(
          provider: .gitHub,
          externalId: "example/repo#42",
          url: "https://github.com/example/repo/issues/42"
        )
      ]
    )

    let plan = TaskBoardStepStageResolver.plan(for: TaskBoardStepStageInputs(item: githubItem))

    #expect(plan.stage == .blocked)
    #expect(plan.inlineLinks.contains(.openTask))
  }

  @Test("An empty pull-request URL surfaces no pull-request link")
  func emptyPullRequestURLHidesLink() {
    let plan = TaskBoardStepStageResolver.plan(
      for: TaskBoardStepStageInputs(
        item: item(
          status: .inReview,
          workflow: TaskBoardWorkflowState(status: .running, prUrl: "")
        ),
        latestRecord: record(taskStatus: .inReview, outcome: .reviewRunning)
      )
    )

    #expect(!plan.inlineLinks.contains(.openPullRequest))
  }

  @Test("Rail node state derives from the current column")
  func railNodeStatesDeriveFromColumn() {
    #expect(TaskBoardStepColumn.todo.nodeState(current: .toReview, isBlocked: false) == .done)
    #expect(TaskBoardStepColumn.toReview.nodeState(current: .toReview, isBlocked: false) == .current)
    #expect(TaskBoardStepColumn.toReview.nodeState(current: .toReview, isBlocked: true) == .failed)
    #expect(TaskBoardStepColumn.inReview.nodeState(current: .toReview, isBlocked: false) == .upcoming)
  }

  // MARK: - Fixtures

  private func item(
    status: TaskBoardStatus,
    sessionId: String? = "sess-1",
    workItemId: String? = "task-1",
    workflow: TaskBoardWorkflowState? = nil,
    externalRefs: [TaskBoardExternalRef] = []
  ) -> TaskBoardItem {
    TaskBoardItem(
      schemaVersion: 1,
      id: "board-1",
      title: "Board item",
      body: "Body",
      status: status,
      priority: .medium,
      tags: [],
      projectId: "project-1",
      targetProjectTypes: [],
      agentMode: .interactive,
      externalRefs: externalRefs,
      planning: TaskBoardPlanningState(),
      workflow: workflow,
      sessionId: sessionId,
      workItemId: workItemId,
      usage: TaskBoardUsage(),
      createdAt: "2026-05-14T10:00:00Z",
      updatedAt: "2026-05-14T10:01:00Z",
      deletedAt: nil
    )
  }

  private func record(
    taskStatus: TaskStatus?,
    outcome: TaskBoardEvaluationOutcome,
    reason: String? = nil
  ) -> TaskBoardEvaluationRecord {
    TaskBoardEvaluationRecord(
      boardItemId: "board-1",
      sessionId: "sess-1",
      workItemId: "task-1",
      outcome: outcome,
      taskStatus: taskStatus,
      reason: reason
    )
  }
}
