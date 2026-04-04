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

public struct HealthResponse: Codable, Equatable, Sendable {
  public let status: String
  public let version: String
  public let pid: Int
  public let endpoint: String
  public let startedAt: String
  public let projectCount: Int
  public let worktreeCount: Int
  public let sessionCount: Int

  public init(
    status: String,
    version: String,
    pid: Int,
    endpoint: String,
    startedAt: String,
    projectCount: Int,
    worktreeCount: Int = 0,
    sessionCount: Int
  ) {
    self.status = status
    self.version = version
    self.pid = pid
    self.endpoint = endpoint
    self.startedAt = startedAt
    self.projectCount = projectCount
    self.worktreeCount = worktreeCount
    self.sessionCount = sessionCount
  }

  enum CodingKeys: String, CodingKey {
    case status, version, pid, endpoint, startedAt, projectCount, worktreeCount, sessionCount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      status: try container.decode(String.self, forKey: .status),
      version: try container.decode(String.self, forKey: .version),
      pid: try container.decode(Int.self, forKey: .pid),
      endpoint: try container.decode(String.self, forKey: .endpoint),
      startedAt: try container.decode(String.self, forKey: .startedAt),
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
