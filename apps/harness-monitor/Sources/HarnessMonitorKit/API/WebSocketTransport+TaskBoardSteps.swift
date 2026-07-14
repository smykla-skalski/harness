import Foundation

extension WebSocketTransport {
  public func pickTaskBoardDispatch(
    request: TaskBoardDispatchPickRequest = TaskBoardDispatchPickRequest()
  ) async throws -> TaskBoardDispatchPickResult {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardDispatchPick, params: params)
    let wire: TaskBoardDispatchPickResponse = try decodePolicyWire(value)
    return TaskBoardDispatchPickResult(wire: wire)
  }

  public func deliverTaskBoardDispatch(
    request: TaskBoardDispatchDeliverRequest
  ) async throws -> TaskBoardDispatchDelivery {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardDispatchDeliver, params: params)
    let wire: TaskBoardDispatchDeliverResponse = try decodePolicyWire(value)
    return try TaskBoardDispatchDelivery(wire: wire)
  }

  public func setPolicyCanvasSpawnRequiresLivePolicy(
    request: PolicyCanvasSetSpawnRequiresLivePolicyRequest
  ) async throws -> PolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .policyCanvasSetSpawnRequiresLivePolicy, params: params)
    return try decodePolicyWire(value)
  }

  public func setPolicyCanvasSpawnKillSwitch(
    request: PolicyCanvasSetSpawnKillSwitchRequest
  ) async throws -> PolicyCanvasWorkspace {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .policyCanvasSetSpawnKillSwitch, params: params)
    return try decodePolicyWire(value)
  }

  public func policyApprovalGrants() async throws -> [PolicyApprovalGrant] {
    let value = try await rpc(method: .policyApprovalGrantsList)
    let response: PolicyApprovalGrantsListResponse = try decodePolicyWire(value)
    return response.grants
  }

  public func resolvePolicyApprovalGrant(
    request: PolicyApprovalGrantResolveRequest
  ) async throws -> PolicyApprovalGrant {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .policyApprovalGrantResolve, params: params)
    let response: PolicyApprovalGrantResolveResponse = try decodePolicyWire(value)
    return response.grant
  }
}
