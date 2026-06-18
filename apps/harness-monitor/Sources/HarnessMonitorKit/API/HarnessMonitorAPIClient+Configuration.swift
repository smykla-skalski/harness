import Foundation

extension HarnessMonitorAPIClient {
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
    if let cached = try await configuration().runtimeProbe {
      return cached
    }
    let wire: AcpRuntimeProbeResponseWire = try await get(
      "/v1/runtimes/probe", decoder: PolicyWireCoding.decoder
    )
    return AcpRuntimeProbeResponse(wire: wire)
  }

  public func acpInspect(sessionID: String?) async throws -> AcpAgentInspectResponse {
    try await get(
      "/v1/managed-agents/acp/inspect",
      queryItems: sessionScopeQueryItems(sessionID: sessionID)
    )
  }

  public func acpTranscript(sessionID: String) async throws -> AcpTranscriptResponse {
    try await get(
      "/v1/managed-agents/acp/transcript",
      queryItems: sessionScopeQueryItems(sessionID: sessionID)
    )
  }

  public func codexInspect(sessionID: String?) async throws -> CodexAgentInspectResponse {
    try await get(
      "/v1/managed-agents/codex/inspect",
      queryItems: sessionScopeQueryItems(sessionID: sessionID)
    )
  }

  public func codexTranscript(sessionID: String) async throws -> CodexTranscriptResponse {
    try await get(
      "/v1/managed-agents/codex/transcript",
      queryItems: sessionScopeQueryItems(sessionID: sessionID)
    )
  }

  public func configuration() async throws -> MonitorConfiguration {
    let wire: WsConfigPayloadWire = try await get("/v1/config", decoder: PolicyWireCoding.decoder)
    return try MonitorConfiguration(wire: wire)
  }

  public func logLevel() async throws -> LogLevelResponse {
    let wire: LogLevelResponseWire = try await get(
      "/v1/daemon/log-level", decoder: PolicyWireCoding.decoder
    )
    return LogLevelResponse(wire: wire)
  }

  public func setLogLevel(_ level: String) async throws -> LogLevelResponse {
    let wire: LogLevelResponseWire = try await put(
      "/v1/daemon/log-level", body: SetLogLevelRequest(level: level),
      decoder: PolicyWireCoding.decoder
    )
    return LogLevelResponse(wire: wire)
  }

  private func sessionScopeQueryItems(sessionID: String?) -> [URLQueryItem] {
    guard let sessionID else {
      return []
    }
    return [
      URLQueryItem(name: "session_id", value: sessionID)
    ]
  }
}
