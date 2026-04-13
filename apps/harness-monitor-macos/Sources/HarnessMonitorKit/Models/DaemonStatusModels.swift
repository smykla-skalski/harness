import Foundation

public struct DaemonStatusReport: Codable, Equatable, Sendable {
  public let manifest: DaemonManifest?
  public let launchAgent: LaunchAgentStatus
  public let projectCount: Int
  public let worktreeCount: Int
  public let sessionCount: Int
  public let diagnostics: DaemonDiagnostics

  public init(
    manifest: DaemonManifest?,
    launchAgent: LaunchAgentStatus,
    projectCount: Int,
    worktreeCount: Int = 0,
    sessionCount: Int,
    diagnostics: DaemonDiagnostics
  ) {
    self.manifest = manifest
    self.launchAgent = launchAgent
    self.projectCount = projectCount
    self.worktreeCount = worktreeCount
    self.sessionCount = sessionCount
    self.diagnostics = diagnostics
  }

  enum CodingKeys: String, CodingKey {
    case manifest, launchAgent, projectCount, worktreeCount, sessionCount, diagnostics
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      manifest: try container.decodeIfPresent(DaemonManifest.self, forKey: .manifest),
      launchAgent: try container.decode(LaunchAgentStatus.self, forKey: .launchAgent),
      projectCount: try container.decode(Int.self, forKey: .projectCount),
      worktreeCount: try container.decodeIfPresent(Int.self, forKey: .worktreeCount) ?? 0,
      sessionCount: try container.decode(Int.self, forKey: .sessionCount),
      diagnostics: try container.decode(DaemonDiagnostics.self, forKey: .diagnostics)
    )
  }
}

extension DaemonStatusReport {
  public init(
    diagnosticsReport: DaemonDiagnosticsReport,
    fallbackProjectCount: Int? = nil,
    fallbackWorktreeCount: Int? = nil,
    fallbackSessionCount: Int? = nil
  ) {
    self.init(
      manifest: diagnosticsReport.manifest,
      launchAgent: diagnosticsReport.launchAgent,
      projectCount: diagnosticsReport.health?.projectCount ?? fallbackProjectCount ?? 0,
      worktreeCount: diagnosticsReport.health?.worktreeCount ?? fallbackWorktreeCount ?? 0,
      sessionCount: diagnosticsReport.health?.sessionCount ?? fallbackSessionCount ?? 0,
      diagnostics: diagnosticsReport.workspace
    )
  }

  public func updating(hostBridge: HostBridgeManifest) -> DaemonStatusReport {
    DaemonStatusReport(
      manifest: manifest?.updating(hostBridge: hostBridge),
      launchAgent: launchAgent,
      projectCount: projectCount,
      worktreeCount: worktreeCount,
      sessionCount: sessionCount,
      diagnostics: diagnostics
    )
  }
}

public struct HealthResponse: Codable, Equatable, Sendable {
  public let status: String
  public let version: String
  public let pid: Int
  public let endpoint: String
  public let startedAt: String
  public let logLevel: String?
  public let projectCount: Int
  public let worktreeCount: Int
  public let sessionCount: Int

  public init(
    status: String,
    version: String,
    pid: Int,
    endpoint: String,
    startedAt: String,
    logLevel: String? = nil,
    projectCount: Int,
    worktreeCount: Int = 0,
    sessionCount: Int
  ) {
    self.status = status
    self.version = version
    self.pid = pid
    self.endpoint = endpoint
    self.startedAt = startedAt
    self.logLevel = logLevel
    self.projectCount = projectCount
    self.worktreeCount = worktreeCount
    self.sessionCount = sessionCount
  }

  enum CodingKeys: String, CodingKey {
    case status, version, pid, endpoint, startedAt, logLevel, projectCount, worktreeCount,
      sessionCount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      status: try container.decode(String.self, forKey: .status),
      version: try container.decode(String.self, forKey: .version),
      pid: try container.decode(Int.self, forKey: .pid),
      endpoint: try container.decode(String.self, forKey: .endpoint),
      startedAt: try container.decode(String.self, forKey: .startedAt),
      logLevel: try container.decodeIfPresent(String.self, forKey: .logLevel),
      projectCount: try container.decode(Int.self, forKey: .projectCount),
      worktreeCount: try container.decodeIfPresent(Int.self, forKey: .worktreeCount) ?? 0,
      sessionCount: try container.decode(Int.self, forKey: .sessionCount)
    )
  }
}

public struct DaemonControlResponse: Codable, Equatable, Sendable {
  public let status: String
}

public struct DaemonDiagnosticsReport: Codable, Equatable, Sendable {
  public let health: HealthResponse?
  public let manifest: DaemonManifest?
  public let launchAgent: LaunchAgentStatus
  public let workspace: DaemonDiagnostics
  public let recentEvents: [DaemonAuditEvent]

  public init(
    health: HealthResponse?,
    manifest: DaemonManifest?,
    launchAgent: LaunchAgentStatus,
    workspace: DaemonDiagnostics,
    recentEvents: [DaemonAuditEvent]
  ) {
    self.health = health
    self.manifest = manifest
    self.launchAgent = launchAgent
    self.workspace = workspace
    self.recentEvents = recentEvents
  }
}
