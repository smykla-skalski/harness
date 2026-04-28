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
  public let prompt: String?
  public let projectDir: String?

  public init(agent: String, prompt: String? = nil, projectDir: String? = nil) {
    self.agent = agent
    self.prompt = prompt
    self.projectDir = projectDir
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
  public let pendingPermissions: Int
  public let terminalCount: Int
  public let promptDeadlineRemainingMs: UInt64

  public var id: String { acpId }
}
