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
  /// Daemon HTTP/WS wire-protocol version. Old daemons that predate the field
  /// decode as `1`; new daemons emit the current value of
  /// `DAEMON_WIRE_VERSION`. The app uses this to detect version skew.
  public let wireVersion: Int

  public init(
    status: String,
    version: String,
    pid: Int,
    endpoint: String,
    startedAt: String,
    logLevel: String? = nil,
    projectCount: Int,
    worktreeCount: Int = 0,
    sessionCount: Int,
    wireVersion: Int = 1
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
    self.wireVersion = wireVersion
  }

  enum CodingKeys: String, CodingKey {
    case status, version, pid, endpoint, startedAt, logLevel, projectCount, worktreeCount,
      sessionCount, wireVersion
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
      sessionCount: try container.decode(Int.self, forKey: .sessionCount),
      wireVersion: try container.decodeIfPresent(Int.self, forKey: .wireVersion) ?? 1
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
  public let githubApi: GitHubApiDiagnostics?
  public let workspace: DaemonDiagnostics
  public let recentEvents: [DaemonAuditEvent]

  public init(
    health: HealthResponse?,
    manifest: DaemonManifest?,
    launchAgent: LaunchAgentStatus,
    githubApi: GitHubApiDiagnostics? = nil,
    workspace: DaemonDiagnostics,
    recentEvents: [DaemonAuditEvent]
  ) {
    self.health = health
    self.manifest = manifest
    self.launchAgent = launchAgent
    self.githubApi = githubApi
    self.workspace = workspace
    self.recentEvents = recentEvents
  }
}

public struct GitHubApiDiagnostics: Codable, Equatable, Sendable {
  public let buckets: [GitHubRateBucketDiagnostics]
  public let cooling: [GitHubCooldownDiagnostics]
  public let lastHourNetworkRequests: UInt64
  public let lastHourGraphqlPoints: UInt64
  public let cacheHits: UInt64
  public let cacheStaleHits: UInt64
  public let cacheDeferredHits: UInt64
  public let deferredBudget: UInt64
  public let topOperations: [GitHubOperationSpendDiagnostics]

  public init(
    buckets: [GitHubRateBucketDiagnostics],
    cooling: [GitHubCooldownDiagnostics],
    lastHourNetworkRequests: UInt64,
    lastHourGraphqlPoints: UInt64,
    cacheHits: UInt64,
    cacheStaleHits: UInt64,
    cacheDeferredHits: UInt64,
    deferredBudget: UInt64,
    topOperations: [GitHubOperationSpendDiagnostics]
  ) {
    self.buckets = buckets
    self.cooling = cooling
    self.lastHourNetworkRequests = lastHourNetworkRequests
    self.lastHourGraphqlPoints = lastHourGraphqlPoints
    self.cacheHits = cacheHits
    self.cacheStaleHits = cacheStaleHits
    self.cacheDeferredHits = cacheDeferredHits
    self.deferredBudget = deferredBudget
    self.topOperations = topOperations
  }
}

public struct GitHubRateBucketDiagnostics: Codable, Equatable, Sendable {
  public let resource: String
  public let remaining: UInt32
  public let limit: UInt32
  public let used: UInt32
  public let resetAt: String

  public init(
    resource: String,
    remaining: UInt32,
    limit: UInt32,
    used: UInt32,
    resetAt: String
  ) {
    self.resource = resource
    self.remaining = remaining
    self.limit = limit
    self.used = used
    self.resetAt = resetAt
  }
}

public struct GitHubCooldownDiagnostics: Codable, Equatable, Sendable {
  public let resource: String
  public let reason: String
  public let untilSecondsFromNow: UInt64

  public init(resource: String, reason: String, untilSecondsFromNow: UInt64) {
    self.resource = resource
    self.reason = reason
    self.untilSecondsFromNow = untilSecondsFromNow
  }
}

public struct GitHubOperationSpendDiagnostics: Codable, Equatable, Sendable {
  public let operation: String
  public let networkRequests: UInt64
  public let graphqlPoints: UInt64

  public init(operation: String, networkRequests: UInt64, graphqlPoints: UInt64) {
    self.operation = operation
    self.networkRequests = networkRequests
    self.graphqlPoints = graphqlPoints
  }
}

extension GitHubApiDiagnostics {
  public static let empty = GitHubApiDiagnostics(
    buckets: [],
    cooling: [],
    lastHourNetworkRequests: 0,
    lastHourGraphqlPoints: 0,
    cacheHits: 0,
    cacheStaleHits: 0,
    cacheDeferredHits: 0,
    deferredBudget: 0,
    topOperations: []
  )
}
