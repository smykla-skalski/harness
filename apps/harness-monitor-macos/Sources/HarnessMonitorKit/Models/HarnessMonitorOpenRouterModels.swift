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
    self.createdAt = createdAt
    self.updatedAt = updatedAt
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
