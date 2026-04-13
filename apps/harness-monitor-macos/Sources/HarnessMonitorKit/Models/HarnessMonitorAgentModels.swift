import Foundation

public struct HookIntegrationDescriptor: Codable, Equatable, Identifiable, Sendable {
  public let name: String
  public let typicalLatencySeconds: Int
  public let supportsContextInjection: Bool

  public var id: String { name }
}

public struct RuntimeCapabilities: Codable, Equatable, Sendable {
  public let runtime: String
  public let supportsNativeTranscript: Bool
  public let supportsSignalDelivery: Bool
  public let supportsContextInjection: Bool
  public let typicalSignalLatencySeconds: Int
  public let hookPoints: [HookIntegrationDescriptor]
}

public enum SessionRole: String, Codable, CaseIterable, Sendable {
  case leader
  case observer
  case worker
  case reviewer
  case improver

  public var title: String {
    switch self {
    case .leader:
      "Leader"
    case .observer:
      "Observer"
    case .worker:
      "Worker"
    case .reviewer:
      "Reviewer"
    case .improver:
      "Improver"
    }
  }
}

public enum AgentStatus: String, Codable, CaseIterable, Sendable {
  case active
  case disconnected
  case removed

  public var title: String {
    switch self {
    case .active:
      "Active"
    case .disconnected:
      "Disconnected"
    case .removed:
      "Removed"
    }
  }
}

/// Icon source for a persona, supporting system SF Symbols or bundled assets.
public enum PersonaSymbol: Codable, Equatable, Sendable {
  case sfSymbol(name: String)
  case asset(name: String)

  enum CodingKeys: String, CodingKey {
    case `type`
    case name
  }

  enum SymbolType: String, Codable {
    case sfSymbol = "sf_symbol"
    case asset
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let symbolType = try container.decode(SymbolType.self, forKey: .type)
    let name = try container.decode(String.self, forKey: .name)
    switch symbolType {
    case .sfSymbol:
      self = .sfSymbol(name: name)
    case .asset:
      self = .asset(name: name)
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .sfSymbol(let name):
      try container.encode(SymbolType.sfSymbol, forKey: .type)
      try container.encode(name, forKey: .name)
    case .asset(let name):
      try container.encode(SymbolType.asset, forKey: .type)
      try container.encode(name, forKey: .name)
    }
  }
}

/// A predefined agent definition that shapes an agent's role and focus.
public struct AgentPersona: Codable, Equatable, Sendable {
  public let identifier: String
  public let name: String
  public let symbol: PersonaSymbol
  public let description: String
}

public struct AgentRegistration: Codable, Equatable, Identifiable, Sendable {
  public let agentId: String
  public let name: String
  public let runtime: String
  public let role: SessionRole
  public let capabilities: [String]
  public let joinedAt: String
  public let updatedAt: String
  public let status: AgentStatus
  public let agentSessionId: String?
  public let lastActivityAt: String?
  public let currentTaskId: String?
  public let runtimeCapabilities: RuntimeCapabilities
  public let persona: AgentPersona?

  public var id: String { agentId }
}

public struct AgentToolActivitySummary: Codable, Equatable, Identifiable, Sendable {
  public let agentId: String
  public let runtime: String
  public let toolInvocationCount: Int
  public let toolResultCount: Int
  public let toolErrorCount: Int
  public let latestToolName: String?
  public let latestEventAt: String?
  public let recentTools: [String]

  public var id: String { agentId }
}
