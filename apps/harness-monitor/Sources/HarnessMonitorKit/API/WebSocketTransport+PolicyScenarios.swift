import Foundation

// Scenario CRUD over the policy-canvas websocket transport. Each call returns the
// post-mutation workspace snapshot (the daemon re-seeds/persists `scenarios_json`
// and replies with the full workspace), decoded through the plain policy decoder.
extension WebSocketTransport {
  public func createPolicyScenario(
    request: PolicyScenarioCreateRequest
  ) async throws -> PolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .policyScenarioCreate, params: params)
    return try decodePolicyWire(value)
  }

  public func updatePolicyScenario(
    request: PolicyScenarioUpdateRequest
  ) async throws -> PolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .policyScenarioUpdate, params: params)
    return try decodePolicyWire(value)
  }

  public func deletePolicyScenario(
    request: PolicyScenarioDeleteRequest
  ) async throws -> PolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .policyScenarioDelete, params: params)
    return try decodePolicyWire(value)
  }

  public func resetPolicyScenarios(
    request: PolicyScenarioResetRequest
  ) async throws -> PolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .policyScenarioReset, params: params)
    return try decodePolicyWire(value)
  }
}
