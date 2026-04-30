import Foundation

public struct AcpAgentDescriptor: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let displayName: String
  public let capabilities: [String]
  public let launchCommand: String
  public let launchArgs: [String]
  public let envPassthrough: [String]
  public let modelCatalog: RuntimeModelCatalog?
  public let installHint: String?
  public let doctorProbe: AcpDoctorProbe
  public let promptTimeoutSeconds: UInt64?

  public init(
    id: String,
    displayName: String,
    capabilities: [String],
    launchCommand: String,
    launchArgs: [String],
    envPassthrough: [String],
    modelCatalog: RuntimeModelCatalog? = nil,
    installHint: String? = nil,
    doctorProbe: AcpDoctorProbe,
    promptTimeoutSeconds: UInt64? = nil
  ) {
    self.id = id
    self.displayName = displayName
    self.capabilities = capabilities
    self.launchCommand = launchCommand
    self.launchArgs = launchArgs
    self.envPassthrough = envPassthrough
    self.modelCatalog = modelCatalog
    self.installHint = installHint
    self.doctorProbe = doctorProbe
    self.promptTimeoutSeconds = promptTimeoutSeconds
  }
}

public struct AcpDoctorProbe: Codable, Equatable, Sendable {
  public let command: String
  public let args: [String]

  public init(command: String, args: [String]) {
    self.command = command
    self.args = args
  }
}

public struct AcpRuntimeProbeResponse: Codable, Equatable, Sendable {
  public let probes: [AcpRuntimeProbe]
  public let checkedAt: String

  public init(probes: [AcpRuntimeProbe], checkedAt: String) {
    self.probes = probes
    self.checkedAt = checkedAt
  }
}

public struct AcpRuntimeProbe: Codable, Equatable, Identifiable, Sendable {
  public let agentId: String
  public let displayName: String
  public let binaryPresent: Bool
  public let authState: AcpAuthState
  public let version: String?
  public let installHint: String?

  public var id: String { agentId }

  public init(
    agentId: String,
    displayName: String,
    binaryPresent: Bool,
    authState: AcpAuthState,
    version: String? = nil,
    installHint: String? = nil
  ) {
    self.agentId = agentId
    self.displayName = displayName
    self.binaryPresent = binaryPresent
    self.authState = authState
    self.version = version
    self.installHint = installHint
  }
}

public enum AcpAuthState: String, Codable, Equatable, Sendable {
  case ready
  case unknown
  case unavailable
}

public struct AcpAgentStartRequest: Codable, Equatable, Sendable {
  public let agent: String
  public let role: SessionRole
  public let fallbackRole: SessionRole?
  public let capabilities: [String]
  public let name: String?
  public let prompt: String?
  public let projectDir: String?
  public let persona: String?
  public let recordPermissions: Bool

  public init(
    agent: String,
    role: SessionRole = .worker,
    fallbackRole: SessionRole? = nil,
    capabilities: [String] = [],
    name: String? = nil,
    prompt: String? = nil,
    projectDir: String? = nil,
    persona: String? = nil,
    recordPermissions: Bool = false
  ) {
    self.agent = agent
    self.role = role
    self.fallbackRole = fallbackRole
    self.capabilities = capabilities
    self.name = name
    self.prompt = prompt
    self.projectDir = projectDir
    self.persona = persona
    self.recordPermissions = recordPermissions
  }
}

public struct AcpAgentInspectResponse: Codable, Equatable, Sendable {
  public let agents: [AcpAgentInspectSnapshot]

  public init(agents: [AcpAgentInspectSnapshot]) {
    self.agents = agents
  }
}

public struct AcpAgentInspectSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let acpId: String
  public let sessionId: String
  public let agentId: String
  public let displayName: String
  public let pid: UInt32
  public let pgid: Int32
  public let uptimeMs: UInt64
  public let lastUpdateAt: String
  public let lastClientCallAt: String?
  public let watchdogState: String
  public let permissionMode: String
  public let permissionLogPath: String?
  public let pendingPermissions: Int
  public let permissionQueueDepth: Int
  public let terminalCount: Int
  public let promptDeadlineRemainingMs: UInt64

  public var id: String { acpId }

  public init(
    acpId: String,
    sessionId: String,
    agentId: String,
    displayName: String,
    pid: UInt32,
    pgid: Int32,
    uptimeMs: UInt64,
    lastUpdateAt: String,
    lastClientCallAt: String?,
    watchdogState: String,
    permissionMode: String = "",
    permissionLogPath: String? = nil,
    pendingPermissions: Int,
    permissionQueueDepth: Int = 0,
    terminalCount: Int,
    promptDeadlineRemainingMs: UInt64
  ) {
    self.acpId = acpId
    self.sessionId = sessionId
    self.agentId = agentId
    self.displayName = displayName
    self.pid = pid
    self.pgid = pgid
    self.uptimeMs = uptimeMs
    self.lastUpdateAt = lastUpdateAt
    self.lastClientCallAt = lastClientCallAt
    self.watchdogState = watchdogState
    self.permissionMode = permissionMode
    self.permissionLogPath = permissionLogPath
    self.pendingPermissions = pendingPermissions
    self.permissionQueueDepth = permissionQueueDepth
    self.terminalCount = terminalCount
    self.promptDeadlineRemainingMs = promptDeadlineRemainingMs
  }

  private enum CodingKeys: String, CodingKey {
    case acpId
    case sessionId
    case agentId
    case displayName
    case pid
    case pgid
    case uptimeMs
    case lastUpdateAt
    case lastClientCallAt
    case watchdogState
    case permissionMode
    case permissionLogPath
    case pendingPermissions
    case permissionQueueDepth
    case terminalCount
    case promptDeadlineRemainingMs
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    acpId = try container.decode(String.self, forKey: .acpId)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    agentId = try container.decode(String.self, forKey: .agentId)
    displayName = try container.decode(String.self, forKey: .displayName)
    pid = try container.decode(UInt32.self, forKey: .pid)
    pgid = try container.decode(Int32.self, forKey: .pgid)
    uptimeMs = try container.decode(UInt64.self, forKey: .uptimeMs)
    lastUpdateAt = try container.decode(String.self, forKey: .lastUpdateAt)
    lastClientCallAt = try container.decodeIfPresent(String.self, forKey: .lastClientCallAt)
    watchdogState = try container.decode(String.self, forKey: .watchdogState)
    permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode) ?? ""
    permissionLogPath = try container.decodeIfPresent(String.self, forKey: .permissionLogPath)
    pendingPermissions = try container.decode(Int.self, forKey: .pendingPermissions)
    permissionQueueDepth =
      try container.decodeIfPresent(
        Int.self,
        forKey: .permissionQueueDepth
      ) ?? 0
    terminalCount = try container.decode(Int.self, forKey: .terminalCount)
    promptDeadlineRemainingMs = try container.decode(
      UInt64.self,
      forKey: .promptDeadlineRemainingMs
    )
  }
}
