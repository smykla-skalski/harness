import Foundation

extension WebSocketTransport {
  public func personas() async throws -> [AgentPersona] {
    try await configuration().personas
  }

  public func runtimeModelCatalogs() async throws -> [RuntimeModelCatalog] {
    try await configuration().runtimeModels
  }

  public func acpAgentDescriptors() async throws -> [AcpAgentDescriptor] {
    try await configuration().acpAgents
  }

  public func runtimeProbeResults() async throws -> AcpRuntimeProbeResponse {
    let value = try await rpc(method: .runtimesProbe)
    return try decode(value)
  }

  public func acpInspect(sessionID: String?) async throws -> AcpAgentInspectResponse {
    var params: [String: JSONValue] = [:]
    if let sessionID {
      params.merge(sessionScopeParams(sessionID: sessionID)) { _, newValue in newValue }
    }
    let value = try await rpc(method: .managedAgentAcpInspect, params: .object(params))
    return try decode(value)
  }

  public func acpTranscript(sessionID: String) async throws -> AcpTranscriptResponse {
    let value = try await rpc(
      method: .managedAgentAcpTranscript,
      params: .object(sessionScopeParams(sessionID: sessionID))
    )
    return try decode(value)
  }

  public func codexInspect(sessionID: String?) async throws -> CodexAgentInspectResponse {
    var params: [String: JSONValue] = [:]
    if let sessionID {
      params.merge(sessionScopeParams(sessionID: sessionID)) { _, newValue in newValue }
    }
    let value = try await rpc(method: .managedAgentCodexInspect, params: .object(params))
    return try decode(value)
  }

  public func codexTranscript(sessionID: String) async throws -> CodexTranscriptResponse {
    let value = try await rpc(
      method: .managedAgentCodexTranscript,
      params: .object(sessionScopeParams(sessionID: sessionID))
    )
    return try decode(value)
  }

  public func openRouterModelCatalog() async throws -> OpenRouterModelCatalogResponse {
    let value = try await rpc(method: .openRouterListModels)
    return try decodePolicyWire(value)
  }

  public func configuration() async throws -> MonitorConfiguration {
    if let cached = cachedConfiguration {
      return cached
    }
    return try await withCheckedThrowingContinuation { continuation in
      configurationWaiters.append(continuation)
    }
  }

  public func logLevel() async throws -> LogLevelResponse {
    let value = try await rpc(method: .daemonLogLevel)
    return try decode(value)
  }

  public func setLogLevel(_ level: String) async throws -> LogLevelResponse {
    let params = JSONValue.object(["level": .string(level)])
    let value = try await rpc(method: .daemonSetLogLevel, params: params)
    return try decode(value)
  }
}
