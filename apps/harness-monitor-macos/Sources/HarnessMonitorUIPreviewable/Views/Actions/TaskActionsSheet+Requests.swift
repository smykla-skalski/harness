import Foundation
import HarnessMonitorKit

@MainActor
enum TaskActionsSheetRequests {
  static func assign(
    store: HarnessMonitorStore,
    taskID: String,
    assigneeID: String
  ) async {
    _ = await store.assignTask(taskID: taskID, agentID: assigneeID)
  }

  static func updateStatus(
    store: HarnessMonitorStore,
    taskID: String,
    status: TaskStatus,
    note: String
  ) async -> Bool {
    await store.updateTaskStatus(
      taskID: taskID,
      status: status,
      note: note.isEmpty ? nil : note
    )
  }

  static func updateQueuePolicy(
    store: HarnessMonitorStore,
    taskID: String,
    queuePolicy: TaskQueuePolicy
  ) async {
    _ = await store.updateTaskQueuePolicy(taskID: taskID, queuePolicy: queuePolicy)
  }

  static func checkpoint(
    store: HarnessMonitorStore,
    taskID: String,
    summary: String,
    progress: Int
  ) async -> Bool {
    await store.checkpointTask(
      taskID: taskID,
      summary: summary,
      progress: progress
    )
  }

  static func submitForReview(
    store: HarnessMonitorStore,
    taskID: String,
    summary: String,
    actorID: String
  ) async -> Bool {
    await store.submitTaskForReview(
      taskID: taskID,
      summary: summary.isEmpty ? nil : summary,
      actor: actorID
    )
  }

  static func claimReview(
    store: HarnessMonitorStore,
    taskID: String,
    actorID: String
  ) async {
    _ = await store.claimTaskReview(taskID: taskID, actor: actorID)
  }

  static func submitReview(
    store: HarnessMonitorStore,
    taskID: String,
    request: TaskActionsReviewSubmission
  ) async -> Bool {
    await store.submitTaskReview(
      taskID: taskID,
      verdict: request.verdict,
      summary: request.summary,
      points: reviewPoints(from: request.pointText),
      actor: request.actorID
    )
  }

  static func respondReview(
    store: HarnessMonitorStore,
    taskID: String,
    response: TaskActionsReviewResponse
  ) async -> Bool {
    await store.respondTaskReview(
      taskID: taskID,
      agreed: response.agreed,
      disputed: response.disputed,
      note: response.note.isEmpty ? nil : response.note,
      actor: response.actorID
    )
  }

  static func arbitrate(
    store: HarnessMonitorStore,
    taskID: String,
    verdict: ReviewVerdict,
    summary: String,
    actorID: String
  ) async -> Bool {
    await store.arbitrateTask(
      taskID: taskID,
      verdict: verdict,
      summary: summary,
      actor: actorID
    )
  }

  private static func reviewPoints(from pointText: String) -> [ReviewPoint] {
    pointText.isEmpty
      ? []
      : [ReviewPoint(pointId: "monitor-\(UUID().uuidString)", text: pointText)]
  }
}

struct TaskActionsReviewSubmission {
  let verdict: ReviewVerdict
  let summary: String
  let pointText: String
  let actorID: String
}

struct TaskActionsReviewResponse {
  let agreed: [String]
  let disputed: [String]
  let note: String
  let actorID: String
}
