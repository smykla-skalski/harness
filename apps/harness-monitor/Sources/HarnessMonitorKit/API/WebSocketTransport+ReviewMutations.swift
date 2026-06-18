import Foundation

extension WebSocketTransport {
  public func submitTaskForReview(
    sessionID: String,
    taskID: String,
    request: TaskSubmitForReviewRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await rpc(method: .taskSubmitForReview, params: params)
    let wire: SessionDetailWire = try decodePolicyWire(value)
    return try SessionDetail(wire: wire)
  }

  public func claimTaskReview(
    sessionID: String,
    taskID: String,
    request: TaskClaimReviewRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await rpc(method: .taskClaimReview, params: params)
    let wire: SessionDetailWire = try decodePolicyWire(value)
    return try SessionDetail(wire: wire)
  }

  public func submitTaskReview(
    sessionID: String,
    taskID: String,
    request: TaskSubmitReviewRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await rpc(method: .taskSubmitReview, params: params)
    let wire: SessionDetailWire = try decodePolicyWire(value)
    return try SessionDetail(wire: wire)
  }

  public func respondTaskReview(
    sessionID: String,
    taskID: String,
    request: TaskRespondReviewRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await rpc(method: .taskRespondReview, params: params)
    let wire: SessionDetailWire = try decodePolicyWire(value)
    return try SessionDetail(wire: wire)
  }

  public func arbitrateTask(
    sessionID: String,
    taskID: String,
    request: TaskArbitrateRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(
      request,
      extra: ["session_id": .string(sessionID), "task_id": .string(taskID)]
    )
    let value = try await rpc(method: .taskArbitrate, params: params)
    let wire: SessionDetailWire = try decodePolicyWire(value)
    return try SessionDetail(wire: wire)
  }

  public func applyImproverPatch(
    sessionID: String,
    request: ImproverApplyRequest
  ) async throws -> SessionDetail {
    let params = try encodeParams(request, extra: ["session_id": .string(sessionID)])
    let value = try await rpc(method: .improverApply, params: params)
    let wire: SessionDetailWire = try decodePolicyWire(value)
    return try SessionDetail(wire: wire)
  }
}
