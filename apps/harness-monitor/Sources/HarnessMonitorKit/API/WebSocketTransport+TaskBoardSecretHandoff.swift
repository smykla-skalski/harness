extension WebSocketTransport {
  public func syncTaskBoardGitRuntimeKeyMaterial(
    request: TaskBoardGitRuntimeKeyMaterialSyncRequest
  ) async throws -> TaskBoardGitRuntimeKeyMaterialSyncResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardGitRuntimeKeyMaterialSync, params: params)
    return try decodePolicyWire(value)
  }

  public func prepareTaskBoardGitRuntimeSecretHandoff() async throws
    -> TaskBoardGitRuntimeSecretHandoffPrepareResponse
  {
    let value = try await rpc(method: .taskBoardGitRuntimeSecretHandoffPrepare)
    let wire: TaskBoardGitRuntimeSecretHandoffPrepareResponseWire = try decodePolicyWire(value)
    return TaskBoardGitRuntimeSecretHandoffPrepareResponse(wire: wire)
  }

  public func acknowledgeTaskBoardGitRuntimeSecretHandoff(
    request: TaskBoardGitRuntimeSecretHandoffAckRequest
  ) async throws -> TaskBoardGitRuntimeSecretHandoffAckResponse {
    let params = try encodeParams(request, extra: [:])
    let value = try await rpc(method: .taskBoardGitRuntimeSecretHandoffAck, params: params)
    return try decodePolicyWire(value)
  }
}
