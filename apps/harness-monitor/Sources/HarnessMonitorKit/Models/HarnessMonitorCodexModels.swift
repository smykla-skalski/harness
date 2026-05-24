import Foundation

public enum CodexRunMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case report
  case workspaceWrite = "workspace_write"
  case approval

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .report:
      "Report"
    case .workspaceWrite:
      "Workspace Write"
    case .approval:
      "Approval"
    }
  }
}

public enum CodexRunStatus: String, Codable, Sendable {
  case queued
  case running
  case waitingApproval = "waiting_approval"
  case completed
  case failed
  case cancelled

  public var title: String {
    switch self {
    case .queued:
      "Queued"
    case .running:
      "Running"
    case .waitingApproval:
      "Waiting Approval"
    case .completed:
      "Completed"
    case .failed:
      "Failed"
    case .cancelled:
      "Cancelled"
    }
  }

  public var isActive: Bool {
    switch self {
    case .queued, .running, .waitingApproval:
      true
    case .completed, .failed, .cancelled:
      false
    }
  }
}

public enum CodexApprovalDecision: String, Codable, CaseIterable, Sendable {
  case accept
  case acceptForSession = "accept_for_session"
  case decline
  case cancel
}

public struct CodexRunRequest: Codable, Equatable, Sendable {
  public let actor: String?
  public let prompt: String
  public let mode: CodexRunMode
  public let role: SessionRole?
  public let fallbackRole: SessionRole?
  public let capabilities: [String]?
  public let name: String?
  public let persona: String?
  public let resumeThreadId: String?
  public let taskID: String?
  public let boardItemID: String?
  public let workflowExecutionID: String?
  public let model: String?
  public let effort: String?
  public let allowCustomModel: Bool

  public init(
    actor: String?,
    prompt: String,
    mode: CodexRunMode,
    role: SessionRole? = nil,
    fallbackRole: SessionRole? = nil,
    capabilities: [String]? = nil,
    name: String? = nil,
    persona: String? = nil,
    resumeThreadId: String? = nil,
    taskID: String? = nil,
    boardItemID: String? = nil,
    workflowExecutionID: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    allowCustomModel: Bool = false
  ) {
    self.actor = actor
    self.prompt = prompt
    self.mode = mode
    self.role = role
    self.fallbackRole = fallbackRole
    self.capabilities = capabilities
    self.name = name
    self.persona = persona
    self.resumeThreadId = resumeThreadId
    self.taskID = taskID
    self.boardItemID = boardItemID
    self.workflowExecutionID = workflowExecutionID
    self.model = model
    self.effort = effort
    self.allowCustomModel = allowCustomModel
  }

  private enum CodingKeys: String, CodingKey {
    case actor
    case prompt
    case mode
    case role
    case fallbackRole
    case capabilities
    case name
    case persona
    case resumeThreadId
    case taskID = "taskId"
    case boardItemID = "boardItemId"
    case workflowExecutionID = "workflowExecutionId"
    case model
    case effort
    case allowCustomModel
  }
}

public struct CodexSteerRequest: Codable, Equatable, Sendable {
  public let prompt: String

  public init(prompt: String) {
    self.prompt = prompt
  }
}

public struct CodexApprovalDecisionRequest: Codable, Equatable, Sendable {
  public let decision: CodexApprovalDecision
}

public struct CodexRunListResponse: Codable, Equatable, Sendable {
  public let runs: [CodexRunSnapshot]
}

public struct CodexAgentInspectResponse: Codable, Equatable, Sendable {
  public let agents: [CodexAgentInspectSnapshot]
  public let daemonPerceivedNow: String?
  public let available: Bool
  public let issueMessage: String?

  public init(
    agents: [CodexAgentInspectSnapshot],
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
    agents = try container.decode([CodexAgentInspectSnapshot].self, forKey: .agents)
    daemonPerceivedNow = try container.decodeIfPresent(String.self, forKey: .daemonPerceivedNow)
    available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? true
    issueMessage = try container.decodeIfPresent(String.self, forKey: .issueMessage)
  }
}

public struct CodexAgentInspectSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let runId: String
  public let sessionId: String
  public let agentId: String?
  public let displayName: String
  public let status: CodexRunStatus
  public let projectDir: String
  public let threadId: String?
  public let turnId: String?
  public let active: Bool
  public let attached: Bool
  public let pendingApprovals: Int
  public let resolvedApprovals: Int
  public let eventCount: Int
  public let lastUpdateAt: String
  public let model: String?
  public let effort: String?
  public let latestSummary: String?
  public let error: String?

  public var id: String { runId }
}

public struct CodexTranscriptResponse: Codable, Equatable, Sendable {
  public let entries: [TimelineEntry]

  public init(entries: [TimelineEntry]) {
    self.entries = entries
  }
}

public struct CodexApprovalRequest: Codable, Equatable, Identifiable, Sendable {
  public let approvalId: String
  public let requestId: String
  public let kind: String
  public let title: String
  public let detail: String
  public let threadId: String?
  public let turnId: String?
  public let itemId: String?
  public let cwd: String?
  public let command: String?
  public let filePath: String?

  public var id: String { approvalId }
}

public struct CodexResolvedApproval: Codable, Equatable, Sendable {
  public let approvalId: String
  public let decision: CodexApprovalDecision
  public let resolvedAt: String
}

public struct CodexRunEvent: Codable, Equatable, Identifiable, Sendable {
  public let eventId: String
  public let sequence: UInt64
  public let recordedAt: String
  public let kind: String
  public let summary: String
  public let threadId: String?
  public let turnId: String?
  public let itemId: String?
  public let payload: JSONValue

  public var id: String { eventId }
}

public struct CodexRunSnapshot: Codable, Equatable, Identifiable, Sendable {
  public let runId: String
  public let sessionId: String
  public let sessionAgentId: String?
  public let displayName: String?
  public let projectDir: String
  public let threadId: String?
  public let turnId: String?
  public let mode: CodexRunMode
  public let status: CodexRunStatus
  public let prompt: String
  public let latestSummary: String?
  public let finalMessage: String?
  public let error: String?
  public let pendingApprovals: [CodexApprovalRequest]
  public let resolvedApprovals: [CodexResolvedApproval]
  public let events: [CodexRunEvent]
  public let createdAt: String
  public let updatedAt: String
  public let model: String?
  public let effort: String?

  enum CodingKeys: String, CodingKey {
    case runId
    case sessionId
    case sessionAgentId
    case displayName
    case projectDir
    case threadId
    case turnId
    case mode
    case status
    case prompt
    case latestSummary
    case finalMessage
    case error
    case pendingApprovals
    case resolvedApprovals
    case events
    case createdAt
    case updatedAt
    case model
    case effort
  }

  public init(
    runId: String,
    sessionId: String,
    sessionAgentId: String? = nil,
    displayName: String? = nil,
    projectDir: String,
    threadId: String?,
    turnId: String?,
    mode: CodexRunMode,
    status: CodexRunStatus,
    prompt: String,
    latestSummary: String?,
    finalMessage: String?,
    error: String?,
    pendingApprovals: [CodexApprovalRequest],
    resolvedApprovals: [CodexResolvedApproval] = [],
    events: [CodexRunEvent] = [],
    createdAt: String,
    updatedAt: String,
    model: String? = nil,
    effort: String? = nil
  ) {
    self.runId = runId
    self.sessionId = sessionId
    self.sessionAgentId = sessionAgentId
    self.displayName = displayName
    self.projectDir = projectDir
    self.threadId = threadId
    self.turnId = turnId
    self.mode = mode
    self.status = status
    self.prompt = prompt
    self.latestSummary = latestSummary
    self.finalMessage = finalMessage
    self.error = error
    self.pendingApprovals = pendingApprovals
    self.resolvedApprovals = resolvedApprovals
    self.events = events
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.model = model
    self.effort = effort
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    runId = try container.decode(String.self, forKey: .runId)
    sessionId = try container.decode(String.self, forKey: .sessionId)
    sessionAgentId = try container.decodeIfPresent(String.self, forKey: .sessionAgentId)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
    projectDir = try container.decode(String.self, forKey: .projectDir)
    threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
    turnId = try container.decodeIfPresent(String.self, forKey: .turnId)
    mode = try container.decode(CodexRunMode.self, forKey: .mode)
    status = try container.decode(CodexRunStatus.self, forKey: .status)
    prompt = try container.decode(String.self, forKey: .prompt)
    latestSummary = try container.decodeIfPresent(String.self, forKey: .latestSummary)
    finalMessage = try container.decodeIfPresent(String.self, forKey: .finalMessage)
    error = try container.decodeIfPresent(String.self, forKey: .error)
    pendingApprovals =
      try container.decodeIfPresent([CodexApprovalRequest].self, forKey: .pendingApprovals) ?? []
    resolvedApprovals =
      try container.decodeIfPresent([CodexResolvedApproval].self, forKey: .resolvedApprovals) ?? []
    events = try container.decodeIfPresent([CodexRunEvent].self, forKey: .events) ?? []
    createdAt = try container.decode(String.self, forKey: .createdAt)
    updatedAt = try container.decode(String.self, forKey: .updatedAt)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    effort = try container.decodeIfPresent(String.self, forKey: .effort)
  }

  public var id: String { runId }
  public var managedAgentID: String { runId }
  public var sessionAgentID: String? { sessionAgentId }
}

public struct CodexApprovalRequestedPayload: Codable, Equatable, Sendable {
  public let run: CodexRunSnapshot
  public let approval: CodexApprovalRequest
}
