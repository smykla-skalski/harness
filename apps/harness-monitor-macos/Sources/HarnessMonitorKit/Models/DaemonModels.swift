public struct DaemonManifest: Codable, Equatable, Sendable {
  public let version: String
  public let pid: Int
  public let endpoint: String
  public let startedAt: String
  public let tokenPath: String

  public init(version: String, pid: Int, endpoint: String, startedAt: String, tokenPath: String) {
    self.version = version
    self.pid = pid
    self.endpoint = endpoint
    self.startedAt = startedAt
    self.tokenPath = tokenPath
  }
}

public struct LaunchAgentStatus: Codable, Equatable, Sendable {
  public let installed: Bool
  public let label: String
  public let path: String

  public init(installed: Bool, label: String, path: String) {
    self.installed = installed
    self.label = label
    self.path = path
  }
}

public struct DaemonStatusReport: Codable, Equatable, Sendable {
  public let manifest: DaemonManifest?
  public let launchAgent: LaunchAgentStatus
  public let projectCount: Int
  public let sessionCount: Int

  public init(
    manifest: DaemonManifest?,
    launchAgent: LaunchAgentStatus,
    projectCount: Int,
    sessionCount: Int
  ) {
    self.manifest = manifest
    self.launchAgent = launchAgent
    self.projectCount = projectCount
    self.sessionCount = sessionCount
  }
}

public struct HealthResponse: Codable, Equatable, Sendable {
  public let status: String
  public let version: String
  public let pid: Int
  public let endpoint: String
  public let startedAt: String
  public let projectCount: Int
  public let sessionCount: Int
}
