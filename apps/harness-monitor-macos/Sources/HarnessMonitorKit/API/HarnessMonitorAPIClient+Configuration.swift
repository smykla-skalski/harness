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
    return try await get("/v1/runtimes/probe")
  }

  public func acpTranscript(sessionID: String) async throws -> AcpTranscriptResponse {
    try await get(
      "/v1/managed-agents/acp/transcript",
      queryItems: [URLQueryItem(name: "session_id", value: sessionID)]
    )
  }

  public func configuration() async throws -> MonitorConfiguration {
    try await get("/v1/config")
  }

  public func logLevel() async throws -> LogLevelResponse {
    try await get("/v1/daemon/log-level")
  }

  public func setLogLevel(_ level: String) async throws -> LogLevelResponse {
    try await put("/v1/daemon/log-level", body: SetLogLevelRequest(level: level))
  }
}
