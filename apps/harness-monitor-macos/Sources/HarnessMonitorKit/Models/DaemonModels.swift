import Foundation

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

public struct DaemonAuditEvent: Codable, Equatable, Identifiable, Sendable {
  public let recordedAt: String
  public let level: String
  public let message: String
  private let stableID = UUID()

  public var id: UUID { stableID }
  enum CodingKeys: String, CodingKey { case recordedAt, level, message }

  public init(recordedAt: String, level: String, message: String) {
    self.recordedAt = recordedAt
    self.level = level
    self.message = message
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.recordedAt == rhs.recordedAt && lhs.level == rhs.level && lhs.message == rhs.message
  }
}

public struct DaemonDiagnostics: Codable, Equatable, Sendable {
  public let daemonRoot: String
  public let manifestPath: String
  public let authTokenPath: String
  public let authTokenPresent: Bool
  public let eventsPath: String
  public let cacheRoot: String
  public let cacheEntryCount: Int
  public let lastEvent: DaemonAuditEvent?

  public init(
    daemonRoot: String,
    manifestPath: String,
    authTokenPath: String,
    authTokenPresent: Bool,
    eventsPath: String,
    cacheRoot: String,
    cacheEntryCount: Int,
    lastEvent: DaemonAuditEvent?
  ) {
    self.daemonRoot = daemonRoot
    self.manifestPath = manifestPath
    self.authTokenPath = authTokenPath
    self.authTokenPresent = authTokenPresent
    self.eventsPath = eventsPath
    self.cacheRoot = cacheRoot
    self.cacheEntryCount = cacheEntryCount
    self.lastEvent = lastEvent
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
  public let diagnostics: DaemonDiagnostics

  public init(
    manifest: DaemonManifest?,
    launchAgent: LaunchAgentStatus,
    projectCount: Int,
    sessionCount: Int,
    diagnostics: DaemonDiagnostics
  ) {
    self.manifest = manifest
    self.launchAgent = launchAgent
    self.projectCount = projectCount
    self.sessionCount = sessionCount
    self.diagnostics = diagnostics
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

public struct DaemonDiagnosticsReport: Codable, Equatable, Sendable {
  public let health: HealthResponse?
  public let manifest: DaemonManifest?
  public let launchAgent: LaunchAgentStatus
  public let workspace: DaemonDiagnostics
  public let recentEvents: [DaemonAuditEvent]
}
