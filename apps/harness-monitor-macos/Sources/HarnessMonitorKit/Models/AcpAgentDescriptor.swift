import Foundation

private func decodeRequiredNonEmptyString<Key: CodingKey>(
  _ container: KeyedDecodingContainer<Key>,
  forKey key: Key
) throws -> String {
  let value = try container.decode(String.self, forKey: key)
  guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw DecodingError.dataCorruptedError(
      forKey: key,
      in: container,
      debugDescription: "\(key.stringValue) must not be empty"
    )
  }
  return value
}

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

  private enum CodingKeys: String, CodingKey {
    case descriptorId
    case role
    case fallbackRole
    case capabilities
    case name
    case prompt
    case projectDir
    case persona
    case recordPermissions
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agent = try decodeRequiredNonEmptyString(container, forKey: .descriptorId)
    role = try container.decodeIfPresent(SessionRole.self, forKey: .role) ?? .worker
    fallbackRole = try container.decodeIfPresent(SessionRole.self, forKey: .fallbackRole)
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    name = try container.decodeIfPresent(String.self, forKey: .name)
    prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
    projectDir = try container.decodeIfPresent(String.self, forKey: .projectDir)
    persona = try container.decodeIfPresent(String.self, forKey: .persona)
    recordPermissions =
      try container.decodeIfPresent(Bool.self, forKey: .recordPermissions) ?? false
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(agent, forKey: .descriptorId)
    try container.encode(role, forKey: .role)
    try container.encodeIfPresent(fallbackRole, forKey: .fallbackRole)
    try container.encode(capabilities, forKey: .capabilities)
    try container.encodeIfPresent(name, forKey: .name)
    try container.encodeIfPresent(prompt, forKey: .prompt)
    try container.encodeIfPresent(projectDir, forKey: .projectDir)
    try container.encodeIfPresent(persona, forKey: .persona)
    try container.encode(recordPermissions, forKey: .recordPermissions)
  }
}

public struct AcpAgentInspectResponse: Codable, Equatable, Sendable {
  public let agents: [AcpAgentInspectSnapshot]
  public let daemonPerceivedNow: String?
  public let available: Bool
  public let issueMessage: String?

  public init(
    agents: [AcpAgentInspectSnapshot],
    daemonPerceivedNow: String? = nil,
    available: Bool = true,
    issueMessage: String? = nil
  ) {
    self.agents = agents
    self.daemonPerceivedNow = daemonPerceivedNow
    self.available = available
    self.issueMessage = issueMessage
  }

  private enum CodingKeys: String, CodingKey {
    case agents
    case daemonPerceivedNow
    case available
    case issueMessage
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agents = try container.decode([AcpAgentInspectSnapshot].self, forKey: .agents)
    daemonPerceivedNow = try container.decodeIfPresent(String.self, forKey: .daemonPerceivedNow)
    available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? true
    issueMessage = try container.decodeIfPresent(String.self, forKey: .issueMessage)
  }

  public var daemonPerceivedNowDate: Date? {
    guard let daemonPerceivedNow else {
      return nil
    }
    return Self.daemonPerceivedNowFormatterFracSeconds.date(from: daemonPerceivedNow)
      ?? Self.daemonPerceivedNowFormatter.date(from: daemonPerceivedNow)
  }

  nonisolated(unsafe) private static let daemonPerceivedNowFormatterFracSeconds:
    ISO8601DateFormatter =
      {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
      }()

  nonisolated(unsafe) private static let daemonPerceivedNowFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
}

public struct AcpTranscriptResponse: Codable, Equatable, Sendable {
  public let entries: [TimelineEntry]

  public init(entries: [TimelineEntry]) {
    self.entries = entries
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
  public var managedAgentID: String { acpId }
  public var sessionAgentID: String { agentId }

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
    case managedAgentId
    case managedAgentFamily
    case sessionId
    case sessionAgentId
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
    try requireAcpManagedAgentFamily(container, forKey: .managedAgentFamily)
    acpId = try container.decode(String.self, forKey: .managedAgentId)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    agentId = try container.decode(String.self, forKey: .sessionAgentId)
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

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(acpId, forKey: .managedAgentId)
    try container.encode("acp", forKey: .managedAgentFamily)
    try container.encode(sessionId, forKey: .sessionId)
    try container.encode(agentId, forKey: .sessionAgentId)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(pid, forKey: .pid)
    try container.encode(pgid, forKey: .pgid)
    try container.encode(uptimeMs, forKey: .uptimeMs)
    try container.encode(lastUpdateAt, forKey: .lastUpdateAt)
    try container.encodeIfPresent(lastClientCallAt, forKey: .lastClientCallAt)
    try container.encode(watchdogState, forKey: .watchdogState)
    try container.encode(permissionMode, forKey: .permissionMode)
    try container.encodeIfPresent(permissionLogPath, forKey: .permissionLogPath)
    try container.encode(pendingPermissions, forKey: .pendingPermissions)
    try container.encode(permissionQueueDepth, forKey: .permissionQueueDepth)
    try container.encode(terminalCount, forKey: .terminalCount)
    try container.encode(promptDeadlineRemainingMs, forKey: .promptDeadlineRemainingMs)
  }
}

extension AcpAgentDescriptor {
  public var descriptorIdentity: AcpDescriptorID {
    AcpDescriptorID(rawValue: id)
  }
}

extension AcpRuntimeProbe {
  public var descriptorIdentity: AcpDescriptorID {
    AcpDescriptorID(rawValue: agentId)
  }
}

extension AcpAgentStartRequest {
  public var descriptorIdentity: AcpDescriptorID {
    AcpDescriptorID(rawValue: agent)
  }
}

extension AcpAgentInspectSnapshot {
  public var managedAgentIdentity: ManagedAgentID {
    ManagedAgentID(rawValue: managedAgentID)
  }

  public var sessionIdentity: HarnessSessionID {
    HarnessSessionID(rawValue: sessionId)
  }

  public var sessionAgentIdentity: SessionAgentID {
    SessionAgentID(rawValue: sessionAgentID)
  }
}
