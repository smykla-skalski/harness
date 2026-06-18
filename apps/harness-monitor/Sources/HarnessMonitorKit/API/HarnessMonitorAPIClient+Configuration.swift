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
    let wire: AcpAgentInspectResponseWire = try await get(
      "/v1/managed-agents/acp/inspect",
      queryItems: sessionScopeQueryItems(sessionID: sessionID),
      decoder: PolicyWireCoding.decoder
    )
    return AcpAgentInspectResponse(wire: wire)
  }

  public func acpTranscript(sessionID: String) async throws -> AcpTranscriptResponse {
    let wire: AcpTranscriptResponseWire = try await get(
      "/v1/managed-agents/acp/transcript",
      queryItems: sessionScopeQueryItems(sessionID: sessionID),
      decoder: PolicyWireCoding.decoder
    )
    return AcpTranscriptResponse(wire: wire)
  }

  public func codexInspect(sessionID: String?) async throws -> CodexAgentInspectResponse {
    let wire: CodexAgentInspectResponseWire = try await get(
      "/v1/managed-agents/codex/inspect",
      queryItems: sessionScopeQueryItems(sessionID: sessionID),
      decoder: PolicyWireCoding.decoder
    )
    return CodexAgentInspectResponse(wire: wire)
  }

  public func codexTranscript(sessionID: String) async throws -> CodexTranscriptResponse {
    let wire: CodexTranscriptResponseWire = try await get(
      "/v1/managed-agents/codex/transcript",
      queryItems: sessionScopeQueryItems(sessionID: sessionID),
      decoder: PolicyWireCoding.decoder
    )
    return CodexTranscriptResponse(wire: wire)
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
