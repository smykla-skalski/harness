import Foundation

extension HarnessMonitorAPIClient {
  public func submitTaskForReview(
    sessionID: String,
    taskID: String,
    request: TaskSubmitForReviewRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/submit-for-review", body: request)
  }

  public func claimTaskReview(
    sessionID: String,
    taskID: String,
    request: TaskClaimReviewRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/claim-review", body: request)
  }

  public func submitTaskReview(
    sessionID: String,
    taskID: String,
    request: TaskSubmitReviewRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/submit-review", body: request)
  }

  public func respondTaskReview(
    sessionID: String,
    taskID: String,
    request: TaskRespondReviewRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/respond-review", body: request)
  }

  public func arbitrateTask(
    sessionID: String,
    taskID: String,
    request: TaskArbitrateRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/tasks/\(taskID)/arbitrate", body: request)
  }

  public func applyImproverPatch(
    sessionID: String,
    request: ImproverApplyRequest
  ) async throws -> SessionDetail {
    try await post("/v1/sessions/\(sessionID)/improver/apply", body: request)
  }
}
