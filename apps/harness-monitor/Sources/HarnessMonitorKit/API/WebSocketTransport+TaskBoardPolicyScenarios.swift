import Foundation

// Scenario CRUD over the policy-canvas websocket transport. Each call returns the
// post-mutation workspace snapshot (the daemon re-seeds/persists `scenarios_json`
// and replies with the full workspace), decoded through the plain policy decoder.
extension WebSocketTransport {
  public func createTaskBoardPolicyScenario(
    request: TaskBoardPolicyScenarioCreateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyScenarioCreate, params: params)
    return try decodePolicyWire(value)
  }

  public func updateTaskBoardPolicyScenario(
    request: TaskBoardPolicyScenarioUpdateRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyScenarioUpdate, params: params)
    return try decodePolicyWire(value)
  }

  public func deleteTaskBoardPolicyScenario(
    request: TaskBoardPolicyScenarioDeleteRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyScenarioDelete, params: params)
    return try decodePolicyWire(value)
  }

  public func resetTaskBoardPolicyScenarios(
    request: TaskBoardPolicyScenarioResetRequest
  ) async throws -> TaskBoardPolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardPolicyScenarioReset, params: params)
    return try decodePolicyWire(value)
  }
}
