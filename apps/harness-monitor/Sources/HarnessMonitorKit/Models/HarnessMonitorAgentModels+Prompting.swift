import Foundation

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
