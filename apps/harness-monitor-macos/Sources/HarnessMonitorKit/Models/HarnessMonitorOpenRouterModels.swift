import Foundation

public enum OpenRouterRunStatus: String, Codable, Sendable {
  case pending
  case streaming
  case idle
  case cancelled
  case failed

  public var title: String {
    switch self {
    case .pending:
      "Pending"
    case .streaming:
      "Streaming"
    case .idle:
      "Idle"
    case .cancelled:
      "Cancelled"
    case .failed:
      "Failed"
    }
  }

  public var isActive: Bool {
    switch self {
    case .pending, .streaming:
      true
    case .idle, .cancelled, .failed:
      false
    }
  }
}

public struct OpenRouterRunSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let runId: String
  public let sessionId: String
  public let sessionAgentId: String?
  public let displayName: String
  public let model: String
  public let status: OpenRouterRunStatus
  public let latestMessage: String?
  public let latestReasoning: String?
  public let finalMessage: String?
  public let error: String?
  public let turnCount: UInt32
  public let pendingPermissionBatches: [AcpPermissionBatch]
  public let createdAt: String
  public let updatedAt: String

  public init(
    runId: String,
    sessionId: String,
    sessionAgentId: String? = nil,
    displayName: String,
    model: String,
    status: OpenRouterRunStatus,
    latestMessage: String? = nil,
    latestReasoning: String? = nil,
    finalMessage: String? = nil,
    error: String? = nil,
    turnCount: UInt32,
    pendingPermissionBatches: [AcpPermissionBatch] = [],
    createdAt: String,
    updatedAt: String
  ) {
    self.runId = runId
    self.sessionId = sessionId
    self.sessionAgentId = sessionAgentId
    self.displayName = displayName
    self.model = model
    self.status = status
    self.latestMessage = latestMessage
    self.latestReasoning = latestReasoning
    self.finalMessage = finalMessage
    self.error = error
    self.turnCount = turnCount
    self.pendingPermissionBatches = pendingPermissionBatches
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    runId = try container.decode(String.self, forKey: .runId)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    sessionAgentId = try container.decodeIfPresent(String.self, forKey: .sessionAgentId)
    displayName = try container.decode(String.self, forKey: .displayName)
    model = try container.decode(String.self, forKey: .model)
    status = try container.decode(OpenRouterRunStatus.self, forKey: .status)
    latestMessage = try container.decodeIfPresent(String.self, forKey: .latestMessage)
    latestReasoning = try container.decodeIfPresent(String.self, forKey: .latestReasoning)
    finalMessage = try container.decodeIfPresent(String.self, forKey: .finalMessage)
    error = try container.decodeIfPresent(String.self, forKey: .error)
    turnCount = try container.decode(UInt32.self, forKey: .turnCount)
    pendingPermissionBatches =
      try container.decodeIfPresent(
        [AcpPermissionBatch].self,
        forKey: .pendingPermissionBatches
      ) ?? []
    createdAt = try container.decode(String.self, forKey: .createdAt)
    updatedAt = try container.decode(String.self, forKey: .updatedAt)
  }

  private enum CodingKeys: String, CodingKey {
    case runId
    case sessionId
    case sessionAgentId
    case displayName
    case model
    case status
    case latestMessage
    case latestReasoning
    case finalMessage
    case error
    case turnCount
    case pendingPermissionBatches
    case createdAt
    case updatedAt
  }

  public var id: String { runId }
  public var managedAgentID: String { runId }
  public var sessionAgentID: String? { sessionAgentId }
}

public struct OpenRouterStartRequest: Codable, Equatable, Sendable {
  public let model: String?
  public let prompt: String?
  public let sessionAgentId: String?
  public let displayName: String?
  public let temperature: Float?
  public let maxTokens: UInt32?
  public let reasoningEffort: String?
  public let projectDir: String?

  public init(
    model: String? = nil,
    prompt: String? = nil,
    sessionAgentId: String? = nil,
    displayName: String? = nil,
    temperature: Float? = nil,
    maxTokens: UInt32? = nil,
    reasoningEffort: String? = nil,
    projectDir: String? = nil
  ) {
    self.model = model
    self.prompt = prompt
    self.sessionAgentId = sessionAgentId
    self.displayName = displayName
    self.temperature = temperature
    self.maxTokens = maxTokens
    self.reasoningEffort = reasoningEffort
    self.projectDir = projectDir
  }
}

public struct OpenRouterPromptRequest: Codable, Equatable, Sendable {
  public let prompt: String

  public init(prompt: String) {
    self.prompt = prompt
  }
}

public struct OpenRouterRunListResponse: Codable, Equatable, Sendable {
  public let runs: [OpenRouterRunSnapshot]

  public init(runs: [OpenRouterRunSnapshot]) {
    self.runs = runs
  }
}

public struct OpenRouterModelEntry: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let name: String?
  public let contextLength: UInt64?
  public let supportedParameters: [String]

  public init(
    id: String,
    name: String? = nil,
    contextLength: UInt64? = nil,
    supportedParameters: [String] = []
  ) {
    self.id = id
    self.name = name
    self.contextLength = contextLength
    self.supportedParameters = supportedParameters
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    contextLength = try container.decodeIfPresent(UInt64.self, forKey: .contextLength)
    supportedParameters =
      try container.decodeIfPresent([String].self, forKey: .supportedParameters) ?? []
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case contextLength
    case supportedParameters
  }
}

public struct OpenRouterModelListResponse: Codable, Equatable, Sendable {
  public let data: [OpenRouterModelEntry]

  public init(data: [OpenRouterModelEntry]) {
    self.data = data
  }
}
