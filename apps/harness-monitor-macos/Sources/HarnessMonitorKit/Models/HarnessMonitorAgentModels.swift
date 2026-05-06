import Foundation

/// Identity glossary for Harness Monitor's session and managed-agent models.
///
/// - `sessionId` is the orchestration `HarnessSessionId`.
/// - `AgentRegistration.agentId` is the per-session `SessionAgentID`.
/// - `ManagedAgentRef.id` / `managedAgentID` is the daemon-owned `ManagedAgentID`.
/// - `agentSessionId` / `runtimeSessionID` is the runtime/log/signal session key and is
///   the future `RuntimeSessionID` wire name.
/// - Descriptor/catalog identifiers are separate and must not be reused as live managed IDs.
/// - `Identifiable.id` on UI models is a view identity, not a transport contract, unless the
///   model explicitly documents otherwise.
///
/// Codex remains managed-only in the current architecture: it belongs to a harness session,
/// but `sessionAgentID` is intentionally `nil` unless codex is later promoted into the
/// session-agent orchestration model.
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

public enum ManagedAgentKind: String, Codable, Sendable {
  case tui
  case acp
}

public struct ManagedAgentRef: Codable, Equatable, Sendable {
  public let kind: ManagedAgentKind
  public let id: String

  public var managedAgentID: String { id }
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
  case awaitingReview = "awaiting_review"
  case idle
  case disconnected
  case removed

  init?(rawOrLegacyValue value: String) {
    switch value {
    case "awaitingReview":
      self = .awaitingReview
    default:
      self.init(rawValue: value)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      guard let status = Self(rawOrLegacyValue: value) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Invalid agent status: \(value)"
        )
      }
      self = status
      return
    }
    let tagged = try decoder.container(keyedBy: TaggedCodingKeys.self)
    let value = try tagged.decode(String.self, forKey: .state)
    guard let status = Self(rawOrLegacyValue: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Invalid agent status: \(value)"
      )
    }
    self = status
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  private enum TaggedCodingKeys: String, CodingKey {
    case state
  }

  public var title: String {
    switch self {
    case .active:
      "Active"
    case .awaitingReview:
      "Awaiting Review"
    case .idle:
      "Idle"
    case .disconnected:
      "Disconnected"
    case .removed:
      "Removed"
    }
  }
}

public struct AgentDisconnectReason: Codable, Equatable, Sendable {
  public let kind: String
  public let code: Int?
  public let signal: Int?

  public var isRestartable: Bool {
    switch kind {
    case "process_exited", "stdio_closed", "transport_closed", "initialize_timeout",
      "prompt_timeout", "watchdog_fired", "oom_killed":
      true
    case "user_cancelled", "daemon_shutdown", "unknown":
      false
    default:
      false
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
  public let managedAgent: ManagedAgentRef?
  public let lastActivityAt: String?
  public let currentTaskId: String?
  public let runtimeCapabilities: RuntimeCapabilities
  public let persona: AgentPersona?

  public var id: String { agentId }
  public var sessionAgentID: String { agentId }
  public var runtimeSessionID: String? { agentSessionId }
  public var managedAgentID: String? { managedAgent?.managedAgentID }

  public init(
    agentId: String,
    name: String,
    runtime: String,
    role: SessionRole,
    capabilities: [String],
    joinedAt: String,
    updatedAt: String,
    status: AgentStatus,
    agentSessionId: String?,
    managedAgent: ManagedAgentRef? = nil,
    lastActivityAt: String?,
    currentTaskId: String?,
    runtimeCapabilities: RuntimeCapabilities,
    persona: AgentPersona?
  ) {
    self.agentId = agentId
    self.name = name
    self.runtime = runtime
    self.role = role
    self.capabilities = capabilities
    self.joinedAt = joinedAt
    self.updatedAt = updatedAt
    self.status = status
    self.agentSessionId = agentSessionId
    self.managedAgent = managedAgent
    self.lastActivityAt = lastActivityAt
    self.currentTaskId = currentTaskId
    self.runtimeCapabilities = runtimeCapabilities
    self.persona = persona
  }

  enum CodingKeys: String, CodingKey {
    case agentId
    case sessionAgentId
    case name
    case runtime
    case descriptorId
    case role
    case capabilities
    case joinedAt
    case updatedAt
    case status
    case agentSessionId
    case runtimeSessionId
    case managedAgent
    case managedAgentId
    case managedAgentFamily
    case lastActivityAt
    case currentTaskId
    case runtimeCapabilities
    case persona
  }

  private struct TaggedRuntime: Codable, Equatable, Sendable {
    let kind: String
    let id: String
  }

  public init(from decoder: Decoder) throws {
    // Accept older cached payloads during the identity migration; new encodes
    // below write only the canonical session/runtime identity fields. Remove
    // these decode fallbacks once supported daemon and persisted-state
    // versions are canonical-only.
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agentId =
      try container.decodeIfPresent(String.self, forKey: .sessionAgentId)
      ?? container.decode(String.self, forKey: .agentId)
    name = try container.decode(String.self, forKey: .name)
    if let runtime = try? container.decode(String.self, forKey: .runtime) {
      self.runtime = runtime
    } else {
      self.runtime = try container.decode(TaggedRuntime.self, forKey: .runtime).id
    }
    role = try container.decode(SessionRole.self, forKey: .role)
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    joinedAt = try container.decode(String.self, forKey: .joinedAt)
    updatedAt = try container.decode(String.self, forKey: .updatedAt)
    status = try container.decode(AgentStatus.self, forKey: .status)
    agentSessionId =
      try container.decodeIfPresent(String.self, forKey: .runtimeSessionId)
      ?? container.decodeIfPresent(String.self, forKey: .agentSessionId)
    if let managedAgent = try container.decodeIfPresent(ManagedAgentRef.self, forKey: .managedAgent) {
      self.managedAgent = managedAgent
    } else if
      let managedAgentID = try container.decodeIfPresent(String.self, forKey: .managedAgentId),
      let managedAgentFamily = try container.decodeIfPresent(
        ManagedAgentKind.self,
        forKey: .managedAgentFamily
      )
    {
      self.managedAgent = ManagedAgentRef(kind: managedAgentFamily, id: managedAgentID)
    } else {
      self.managedAgent = nil
    }
    lastActivityAt = try container.decodeIfPresent(String.self, forKey: .lastActivityAt)
    currentTaskId = try container.decodeIfPresent(String.self, forKey: .currentTaskId)
    runtimeCapabilities = try container.decode(
      RuntimeCapabilities.self,
      forKey: .runtimeCapabilities
    )
    persona = try container.decodeIfPresent(AgentPersona.self, forKey: .persona)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(agentId, forKey: .sessionAgentId)
    try container.encode(name, forKey: .name)
    try container.encode(runtime, forKey: .runtime)
    if managedAgent?.kind == .acp {
      try container.encode(runtime, forKey: .descriptorId)
    }
    try container.encode(role, forKey: .role)
    try container.encode(capabilities, forKey: .capabilities)
    try container.encode(joinedAt, forKey: .joinedAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(status, forKey: .status)
    try container.encodeIfPresent(agentSessionId, forKey: .runtimeSessionId)
    try container.encodeIfPresent(managedAgent, forKey: .managedAgent)
    try container.encodeIfPresent(managedAgent?.managedAgentID, forKey: .managedAgentId)
    try container.encodeIfPresent(managedAgent?.kind, forKey: .managedAgentFamily)
    try container.encodeIfPresent(lastActivityAt, forKey: .lastActivityAt)
    try container.encodeIfPresent(currentTaskId, forKey: .currentTaskId)
    try container.encode(runtimeCapabilities, forKey: .runtimeCapabilities)
    try container.encodeIfPresent(persona, forKey: .persona)
  }
}

public struct AgentPendingUserPromptOption: Codable, Equatable, Sendable {
  public let label: String
  public let description: String

  public init(label: String, description: String = "") {
    self.label = label
    self.description = description
  }
}

public struct AgentPendingUserPromptQuestion: Codable, Equatable, Sendable {
  public let question: String
  public let header: String?
  public let options: [AgentPendingUserPromptOption]
  public let multiSelect: Bool

  public init(
    question: String,
    header: String? = nil,
    options: [AgentPendingUserPromptOption] = [],
    multiSelect: Bool = false
  ) {
    self.question = question
    self.header = header
    self.options = options
    self.multiSelect = multiSelect
  }
}

public struct AgentPendingUserPrompt: Codable, Equatable, Sendable {
  public let toolName: String
  public let waitingSince: String?
  public let questions: [AgentPendingUserPromptQuestion]

  enum CodingKeys: String, CodingKey {
    case toolName
    case waitingSince
    case questions
    case message
  }

  public init(
    toolName: String,
    waitingSince: String? = nil,
    questions: [AgentPendingUserPromptQuestion]
  ) {
    self.toolName = toolName
    self.waitingSince = waitingSince
    self.questions = questions
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let toolName = try container.decode(String.self, forKey: .toolName)
    let waitingSince = try container.decodeIfPresent(String.self, forKey: .waitingSince)
    let questions: [AgentPendingUserPromptQuestion] =
      if let decodedQuestions = try container.decodeIfPresent(
        [AgentPendingUserPromptQuestion].self,
        forKey: .questions
      ),
        !decodedQuestions.isEmpty
      {
        decodedQuestions
      } else if let message = try container.decodeIfPresent(String.self, forKey: .message),
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        [AgentPendingUserPromptQuestion(question: message)]
      } else {
        []
      }

    self.init(toolName: toolName, waitingSince: waitingSince, questions: questions)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(toolName, forKey: .toolName)
    try container.encodeIfPresent(waitingSince, forKey: .waitingSince)
    try container.encode(questions, forKey: .questions)
  }

  public var primaryQuestion: AgentPendingUserPromptQuestion? {
    questions.first(where: {
      !$0.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })
  }
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
  public let pendingUserPrompt: AgentPendingUserPrompt?

  public init(
    agentId: String,
    runtime: String,
    toolInvocationCount: Int,
    toolResultCount: Int,
    toolErrorCount: Int,
    latestToolName: String?,
    latestEventAt: String?,
    recentTools: [String],
    pendingUserPrompt: AgentPendingUserPrompt? = nil
  ) {
    self.agentId = agentId
    self.runtime = runtime
    self.toolInvocationCount = toolInvocationCount
    self.toolResultCount = toolResultCount
    self.toolErrorCount = toolErrorCount
    self.latestToolName = latestToolName
    self.latestEventAt = latestEventAt
    self.recentTools = recentTools
    self.pendingUserPrompt = pendingUserPrompt
  }

  public var id: String { agentId }
}
