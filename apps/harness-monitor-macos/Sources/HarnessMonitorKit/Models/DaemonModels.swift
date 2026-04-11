import Foundation

public struct HostBridgeCapabilityManifest: Codable, Equatable, Sendable {
  public let enabled: Bool
  public let healthy: Bool
  public let transport: String
  public let endpoint: String?
  public let metadata: [String: String]

  public init(
    enabled: Bool = true,
    healthy: Bool,
    transport: String,
    endpoint: String? = nil,
    metadata: [String: String] = [:]
  ) {
    self.enabled = enabled
    self.healthy = healthy
    self.transport = transport
    self.endpoint = endpoint
    self.metadata = metadata
  }
}

public struct HostBridgeManifest: Codable, Equatable, Sendable {
  public let running: Bool
  public let socketPath: String?
  public let capabilities: [String: HostBridgeCapabilityManifest]

  public init(
    running: Bool = false,
    socketPath: String? = nil,
    capabilities: [String: HostBridgeCapabilityManifest] = [:]
  ) {
    self.running = running
    self.socketPath = socketPath
    self.capabilities = capabilities
  }
}

public struct BridgeStatusReport: Codable, Equatable, Sendable {
  public let running: Bool
  public let socketPath: String?
  public let pid: Int?
  public let startedAt: String?
  public let uptimeSeconds: Int?
  public let capabilities: [String: HostBridgeCapabilityManifest]

  public init(
    running: Bool,
    socketPath: String? = nil,
    pid: Int? = nil,
    startedAt: String? = nil,
    uptimeSeconds: Int? = nil,
    capabilities: [String: HostBridgeCapabilityManifest] = [:]
  ) {
    self.running = running
    self.socketPath = socketPath
    self.pid = pid
    self.startedAt = startedAt
    self.uptimeSeconds = uptimeSeconds
    self.capabilities = capabilities
  }

  public var hostBridgeManifest: HostBridgeManifest {
    HostBridgeManifest(
      running: running,
      socketPath: socketPath,
      capabilities: capabilities
    )
  }
}

public struct DaemonManifest: Codable, Equatable, Sendable {
  public let version: String
  public let pid: Int
  public let endpoint: String
  public let startedAt: String
  public let tokenPath: String
  public let sandboxed: Bool
  public let hostBridge: HostBridgeManifest
  /// Monotonic counter bumped by the daemon on every manifest write. The
  /// Swift `ManifestWatcher` uses it to detect in-place updates (e.g.
  /// `hostBridge` transitions) so it can refresh the store without a full
  /// reconnect. Legacy manifests without the field decode as 0.
  public let revision: UInt64
  /// UTC timestamp of the most recent daemon-side manifest write. Legacy
  /// manifests without the field decode as nil.
  public let updatedAt: String?

  public init(
    version: String,
    pid: Int,
    endpoint: String,
    startedAt: String,
    tokenPath: String,
    sandboxed: Bool = false,
    hostBridge: HostBridgeManifest = .init(),
    revision: UInt64 = 0,
    updatedAt: String? = nil
  ) {
    self.version = version
    self.pid = pid
    self.endpoint = endpoint
    self.startedAt = startedAt
    self.tokenPath = tokenPath
    self.sandboxed = sandboxed
    self.hostBridge = hostBridge
    self.revision = revision
    self.updatedAt = updatedAt
  }

  enum CodingKeys: String, CodingKey {
    case version, pid, endpoint, startedAt, tokenPath
    case sandboxed, hostBridge, codexTransport, codexEndpoint
    case revision, updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let sandboxed = try container.decodeIfPresent(Bool.self, forKey: .sandboxed) ?? false
    let hostBridge =
      try container.decodeIfPresent(HostBridgeManifest.self, forKey: .hostBridge)
      ?? Self.legacyHostBridge(from: container)
    let revision = try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
    let updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    self.init(
      version: try container.decode(String.self, forKey: .version),
      pid: try container.decode(Int.self, forKey: .pid),
      endpoint: try container.decode(String.self, forKey: .endpoint),
      startedAt: try container.decode(String.self, forKey: .startedAt),
      tokenPath: try container.decode(String.self, forKey: .tokenPath),
      sandboxed: sandboxed,
      hostBridge: hostBridge,
      revision: revision,
      updatedAt: updatedAt
    )
  }

  private static func legacyHostBridge(
    from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> HostBridgeManifest {
    let transport = try container.decodeIfPresent(String.self, forKey: .codexTransport) ?? "stdio"
    let endpoint = try container.decodeIfPresent(String.self, forKey: .codexEndpoint)
    guard transport == "websocket", let endpoint else {
      return HostBridgeManifest()
    }
    return HostBridgeManifest(
      running: true,
      socketPath: nil,
      capabilities: [
        "codex": HostBridgeCapabilityManifest(
          healthy: true,
          transport: transport,
          endpoint: endpoint
        )
      ]
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(version, forKey: .version)
    try container.encode(pid, forKey: .pid)
    try container.encode(endpoint, forKey: .endpoint)
    try container.encode(startedAt, forKey: .startedAt)
    try container.encode(tokenPath, forKey: .tokenPath)
    try container.encode(sandboxed, forKey: .sandboxed)
    try container.encode(hostBridge, forKey: .hostBridge)
    try container.encode(revision, forKey: .revision)
    try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
  }
}

extension DaemonManifest {
  public func updating(hostBridge: HostBridgeManifest) -> DaemonManifest {
    DaemonManifest(
      version: version,
      pid: pid,
      endpoint: endpoint,
      startedAt: startedAt,
      tokenPath: tokenPath,
      sandboxed: sandboxed,
      hostBridge: hostBridge,
      revision: revision,
      updatedAt: updatedAt
    )
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
  public let databasePath: String
  public let databaseSizeBytes: Int
  public let lastEvent: DaemonAuditEvent?

  public init(
    daemonRoot: String,
    manifestPath: String,
    authTokenPath: String,
    authTokenPresent: Bool,
    eventsPath: String,
    databasePath: String,
    databaseSizeBytes: Int,
    lastEvent: DaemonAuditEvent?
  ) {
    self.daemonRoot = daemonRoot
    self.manifestPath = manifestPath
    self.authTokenPath = authTokenPath
    self.authTokenPresent = authTokenPresent
    self.eventsPath = eventsPath
    self.databasePath = databasePath
    self.databaseSizeBytes = databaseSizeBytes
    self.lastEvent = lastEvent
  }

  enum CodingKeys: String, CodingKey {
    case daemonRoot, manifestPath, authTokenPath, authTokenPresent
    case eventsPath, databasePath, databaseSizeBytes, lastEvent
    case cacheRoot, cacheEntryCount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let daemonRoot = try container.decode(String.self, forKey: .daemonRoot)
    let defaultDatabasePath = URL(fileURLWithPath: daemonRoot).appendingPathComponent("harness.db")
      .path

    self.init(
      daemonRoot: daemonRoot,
      manifestPath: try container.decode(String.self, forKey: .manifestPath),
      authTokenPath: try container.decode(String.self, forKey: .authTokenPath),
      authTokenPresent: try container.decode(Bool.self, forKey: .authTokenPresent),
      eventsPath: try container.decode(String.self, forKey: .eventsPath),
      databasePath: try container.decodeIfPresent(String.self, forKey: .databasePath)
        ?? defaultDatabasePath,
      databaseSizeBytes: try container.decodeIfPresent(Int.self, forKey: .databaseSizeBytes) ?? 0,
      lastEvent: try container.decodeIfPresent(DaemonAuditEvent.self, forKey: .lastEvent)
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(daemonRoot, forKey: .daemonRoot)
    try container.encode(manifestPath, forKey: .manifestPath)
    try container.encode(authTokenPath, forKey: .authTokenPath)
    try container.encode(authTokenPresent, forKey: .authTokenPresent)
    try container.encode(eventsPath, forKey: .eventsPath)
    try container.encode(databasePath, forKey: .databasePath)
    try container.encode(databaseSizeBytes, forKey: .databaseSizeBytes)
    try container.encodeIfPresent(lastEvent, forKey: .lastEvent)
  }
}

public struct LaunchAgentStatus: Codable, Equatable, Sendable {
  public let installed: Bool
  public let loaded: Bool
  public let label: String
  public let path: String
  public let domainTarget: String
  public let serviceTarget: String
  public let state: String?
  public let pid: Int?
  public let lastExitStatus: Int?
  public let statusError: String?

  public init(
    installed: Bool,
    loaded: Bool = false,
    label: String,
    path: String,
    domainTarget: String = "",
    serviceTarget: String = "",
    state: String? = nil,
    pid: Int? = nil,
    lastExitStatus: Int? = nil,
    statusError: String? = nil
  ) {
    self.installed = installed
    self.loaded = loaded
    self.label = label
    self.path = path
    self.domainTarget = domainTarget
    self.serviceTarget = serviceTarget
    self.state = state
    self.pid = pid
    self.lastExitStatus = lastExitStatus
    self.statusError = statusError
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    installed = try container.decode(Bool.self, forKey: .installed)
    loaded = try container.decodeIfPresent(Bool.self, forKey: .loaded) ?? false
    label = try container.decode(String.self, forKey: .label)
    path = try container.decode(String.self, forKey: .path)
    domainTarget = try container.decodeIfPresent(String.self, forKey: .domainTarget) ?? ""
    serviceTarget = try container.decodeIfPresent(String.self, forKey: .serviceTarget) ?? ""
    state = try container.decodeIfPresent(String.self, forKey: .state)
    pid = try container.decodeIfPresent(Int.self, forKey: .pid)
    lastExitStatus = try container.decodeIfPresent(Int.self, forKey: .lastExitStatus)
    statusError = try container.decodeIfPresent(String.self, forKey: .statusError)
  }

  enum CodingKeys: String, CodingKey {
    case installed, loaded, label, path, domainTarget, serviceTarget
    case state, pid, lastExitStatus, statusError
  }

  public var lifecycleTitle: String {
    if pid != nil {
      return "Running"
    }
    if loaded {
      return state?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Loaded"
    }
    if installed {
      return "Installed"
    }
    return "Manual"
  }

  public var lifecycleCaption: String {
    if let statusError, !statusError.isEmpty {
      return statusError
    }

    var parts: [String] = []
    if !serviceTarget.isEmpty {
      parts.append(serviceTarget)
    } else if !label.isEmpty {
      parts.append(label)
    }

    if let pid {
      parts.append("pid " + String(pid))
    } else if let state, loaded {
      parts.append(state.replacingOccurrences(of: "_", with: " "))
    } else if loaded {
      parts.append("loaded")
    }

    if let lastExitStatus {
      parts.append("exit \(lastExitStatus)")
    }

    return parts.joined(separator: " • ")
  }
}

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
