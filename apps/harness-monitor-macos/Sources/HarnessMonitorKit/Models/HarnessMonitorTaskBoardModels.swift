import Foundation

public enum TaskBoardStatus: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case new
  case planning
  case planReview
  case needsYou
  case todo
  case inProgress
  case inReview
  case done
  case blocked
  case unknown(String)

  public static let allCases: [TaskBoardStatus] = [
    .new,
    .planning,
    .planReview,
    .needsYou,
    .todo,
    .inProgress,
    .inReview,
    .done,
    .blocked,
  ]

  public var rawValue: String {
    switch self {
    case .new: "new"
    case .planning: "planning"
    case .planReview: "plan_review"
    case .needsYou: "needs_you"
    case .todo: "todo"
    case .inProgress: "in_progress"
    case .inReview: "in_review"
    case .done: "done"
    case .blocked: "blocked"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "new": self = .new
    case "planning": self = .planning
    case "plan_review": self = .planReview
    case "needs_you": self = .needsYou
    case "todo": self = .todo
    case "in_progress": self = .inProgress
    case "in_review": self = .inReview
    case "done": self = .done
    case "blocked": self = .blocked
    default: self = .unknown(rawValue)
    }
  }

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .new:
      "New"
    case .planning:
      "Planning"
    case .planReview:
      "Plan Review"
    case .needsYou:
      "Needs You"
    case .todo:
      "Ready"
    case .inProgress:
      "In Progress"
    case .inReview:
      "In Review"
    case .done:
      "Done"
    case .blocked:
      "Blocked"
    case .unknown(let raw):
      raw
    }
  }
}

public enum TaskBoardPriority: String, Codable, CaseIterable, Identifiable, Sendable {
  case low
  case medium
  case high
  case critical

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .low:
      "Low"
    case .medium:
      "Medium"
    case .high:
      "High"
    case .critical:
      "Critical"
    }
  }
}

public enum TaskBoardAgentMode: TaskBoardOpenEnum, CaseIterable, Identifiable {
  case headless
  case interactive
  case planning
  case evaluate
  case unknown(String)

  public static let allCases: [TaskBoardAgentMode] = [
    .headless,
    .interactive,
    .planning,
    .evaluate,
  ]

  public var rawValue: String {
    switch self {
    case .headless: "headless"
    case .interactive: "interactive"
    case .planning: "planning"
    case .evaluate: "evaluate"
    case .unknown(let raw): raw
    }
  }

  public init(rawValue: String) {
    switch rawValue {
    case "headless": self = .headless
    case "interactive": self = .interactive
    case "planning": self = .planning
    case "evaluate": self = .evaluate
    default: self = .unknown(rawValue)
    }
  }

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .headless:
      "Headless"
    case .interactive:
      "Interactive"
    case .planning:
      "Planning"
    case .evaluate:
      "Evaluate"
    case .unknown(let raw):
      raw
    }
  }
}

public enum TaskBoardExternalRefProvider: String, Codable, Sendable {
  case gitHub = "git_hub"
  case todoist
}

public struct TaskBoardExternalRef: Codable, Equatable, Sendable {
  public let provider: TaskBoardExternalRefProvider
  public let externalId: String
  public let url: String?

  public init(provider: TaskBoardExternalRefProvider, externalId: String, url: String? = nil) {
    self.provider = provider
    self.externalId = externalId
    self.url = url
  }
}

public struct TaskBoardPlanningState: Codable, Equatable, Sendable {
  public let summary: String?
  public let approvedBy: String?
  public let approvedAt: String?

  public init(summary: String? = nil, approvedBy: String? = nil, approvedAt: String? = nil) {
    self.summary = summary
    self.approvedBy = approvedBy
    self.approvedAt = approvedAt
  }
}

public enum TaskBoardWorkflowStatus: String, Codable, CaseIterable, Sendable {
  case idle
  case running
  case paused
  case completed
  case failed
  case cancelled
}

public struct TaskBoardWorkflowState: Codable, Equatable, Sendable {
  public let executionId: String?
  public let status: TaskBoardWorkflowStatus
  public let currentStepId: String?
  public let attempts: UInt32
  public let branch: String?
  public let worktree: String?
  public let prNumber: UInt64?
  public let prUrl: String?
  public let lastError: String?
  public let policyTraceIds: [String]

  public init(
    executionId: String? = nil,
    status: TaskBoardWorkflowStatus = .idle,
    currentStepId: String? = nil,
    attempts: UInt32 = 0,
    branch: String? = nil,
    worktree: String? = nil,
    prNumber: UInt64? = nil,
    prUrl: String? = nil,
    lastError: String? = nil,
    policyTraceIds: [String] = []
  ) {
    self.executionId = executionId
    self.status = status
    self.currentStepId = currentStepId
    self.attempts = attempts
    self.branch = branch
    self.worktree = worktree
    self.prNumber = prNumber
    self.prUrl = prUrl
    self.lastError = lastError
    self.policyTraceIds = policyTraceIds
  }
}

extension TaskBoardWorkflowState {
  enum CodingKeys: String, CodingKey {
    case executionId
    case status
    case currentStepId
    case attempts
    case branch
    case worktree
    case prNumber
    case prUrl
    case lastError
    case policyTraceIds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      executionId: try container.decodeIfPresent(String.self, forKey: .executionId),
      status: try container.decodeIfPresent(TaskBoardWorkflowStatus.self, forKey: .status) ?? .idle,
      currentStepId: try container.decodeIfPresent(String.self, forKey: .currentStepId),
      attempts: try container.decodeIfPresent(UInt32.self, forKey: .attempts) ?? 0,
      branch: try container.decodeIfPresent(String.self, forKey: .branch),
      worktree: try container.decodeIfPresent(String.self, forKey: .worktree),
      prNumber: try container.decodeIfPresent(UInt64.self, forKey: .prNumber),
      prUrl: try container.decodeIfPresent(String.self, forKey: .prUrl),
      lastError: try container.decodeIfPresent(String.self, forKey: .lastError),
      policyTraceIds: try container.decodeIfPresent([String].self, forKey: .policyTraceIds) ?? []
    )
  }
}

public struct TaskBoardUsage: Codable, Equatable, Sendable {
  public let inputTokens: UInt64?
  public let outputTokens: UInt64?
  public let costUsd: Double?

  public init(inputTokens: UInt64? = nil, outputTokens: UInt64? = nil, costUsd: Double? = nil) {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.costUsd = costUsd
  }
}

public struct TaskBoardItem: Codable, Equatable, Identifiable, Sendable {
  public let schemaVersion: UInt32
  public let id: String
  public let title: String
  public let body: String
  public let status: TaskBoardStatus
  public let priority: TaskBoardPriority
  public let tags: [String]
  public let projectId: String?
  public let targetProjectTypes: [String]
  public let agentMode: TaskBoardAgentMode
  public let externalRefs: [TaskBoardExternalRef]
  public let planning: TaskBoardPlanningState
  public let workflow: TaskBoardWorkflowState?
  public let sessionId: String?
  public let workItemId: String?
  public let usage: TaskBoardUsage
  public let createdAt: String
  public let updatedAt: String
  public let deletedAt: String?

  public init(
    schemaVersion: UInt32,
    id: String,
    title: String,
    body: String,
    status: TaskBoardStatus,
    priority: TaskBoardPriority,
    tags: [String],
    projectId: String?,
    targetProjectTypes: [String] = [],
    agentMode: TaskBoardAgentMode,
    externalRefs: [TaskBoardExternalRef],
    planning: TaskBoardPlanningState,
    workflow: TaskBoardWorkflowState?,
    sessionId: String?,
    workItemId: String?,
    usage: TaskBoardUsage,
    createdAt: String,
    updatedAt: String,
    deletedAt: String?
  ) {
    self.schemaVersion = schemaVersion
    self.id = id
    self.title = title
    self.body = body
    self.status = status
    self.priority = priority
    self.tags = tags
    self.projectId = projectId
    self.targetProjectTypes = targetProjectTypes
    self.agentMode = agentMode
    self.externalRefs = externalRefs
    self.planning = planning
    self.workflow = workflow
    self.sessionId = sessionId
    self.workItemId = workItemId
    self.usage = usage
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.deletedAt = deletedAt
  }
}

extension TaskBoardItem {
  enum CodingKeys: String, CodingKey {
    case schemaVersion
    case id
    case title
    case body
    case status
    case priority
    case tags
    case projectId
    case targetProjectTypes
    case agentMode
    case externalRefs
    case planning
    case workflow
    case sessionId
    case workItemId
    case usage
    case createdAt
    case updatedAt
    case deletedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.schemaVersion = try container.decode(UInt32.self, forKey: .schemaVersion)
    self.id = try container.decode(String.self, forKey: .id)
    self.title = try container.decode(String.self, forKey: .title)
    self.body = try container.decode(String.self, forKey: .body)
    self.status = try container.decode(TaskBoardStatus.self, forKey: .status)
    self.priority = try container.decode(TaskBoardPriority.self, forKey: .priority)
    self.tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
    self.projectId = try container.decodeIfPresent(String.self, forKey: .projectId)
    self.targetProjectTypes =
      try container.decodeIfPresent([String].self, forKey: .targetProjectTypes) ?? []
    self.agentMode = try container.decode(TaskBoardAgentMode.self, forKey: .agentMode)
    self.externalRefs =
      try container.decodeIfPresent([TaskBoardExternalRef].self, forKey: .externalRefs) ?? []
    self.planning = try container.decode(TaskBoardPlanningState.self, forKey: .planning)
    self.workflow = try container.decodeIfPresent(TaskBoardWorkflowState.self, forKey: .workflow)
    self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    self.workItemId = try container.decodeIfPresent(String.self, forKey: .workItemId)
    self.usage = try container.decode(TaskBoardUsage.self, forKey: .usage)
    self.createdAt = try container.decode(String.self, forKey: .createdAt)
    self.updatedAt = try container.decode(String.self, forKey: .updatedAt)
    self.deletedAt = try container.decodeIfPresent(String.self, forKey: .deletedAt)
  }
}

public struct TaskBoardCreateItemRequest: Codable, Equatable, Sendable {
  public let title: String
  public let body: String
  public let priority: TaskBoardPriority
  public let agentMode: TaskBoardAgentMode
  public let tags: [String]
  public let projectId: String?
  public let targetProjectTypes: [String]
  public let externalRefs: [TaskBoardExternalRef]
  public let planning: TaskBoardPlanningState
  public let workflow: TaskBoardWorkflowState?
  public let sessionId: String?
  public let workItemId: String?
  public let id: String?

  public init(
    title: String,
    body: String = "",
    priority: TaskBoardPriority = .medium,
    agentMode: TaskBoardAgentMode = .headless,
    tags: [String] = [],
    projectId: String? = nil,
    targetProjectTypes: [String] = [],
    externalRefs: [TaskBoardExternalRef] = [],
    planning: TaskBoardPlanningState = TaskBoardPlanningState(),
    workflow: TaskBoardWorkflowState? = nil,
    sessionId: String? = nil,
    workItemId: String? = nil,
    id: String? = nil
  ) {
    self.title = title
    self.body = body
    self.priority = priority
    self.agentMode = agentMode
    self.tags = tags
    self.projectId = projectId
    self.targetProjectTypes = targetProjectTypes
    self.externalRefs = externalRefs
    self.planning = planning
    self.workflow = workflow
    self.sessionId = sessionId
    self.workItemId = workItemId
    self.id = id
  }
}

public struct TaskBoardListItemsRequest: Codable, Equatable, Sendable {
  public let status: TaskBoardStatus?

  public init(status: TaskBoardStatus? = nil) {
    self.status = status
  }
}

public struct TaskBoardStatusFilterRequest: Codable, Equatable, Sendable {
  public let status: TaskBoardStatus?

  public init(status: TaskBoardStatus? = nil) {
    self.status = status
  }
}

public enum TaskBoardExternalSyncDirection: String, Codable, CaseIterable, Sendable {
  case pull
  case push
  case both
}

public struct TaskBoardSyncRequest: Codable, Equatable, Sendable {
  public let status: TaskBoardStatus?
  public let provider: TaskBoardExternalProvider?
  public let direction: TaskBoardExternalSyncDirection
  public let dryRun: Bool

  public init(
    status: TaskBoardStatus? = nil,
    provider: TaskBoardExternalProvider? = nil,
    direction: TaskBoardExternalSyncDirection = .both,
    dryRun: Bool = true
  ) {
    self.status = status
    self.provider = provider
    self.direction = direction
    self.dryRun = dryRun
  }
}

public struct TaskBoardDispatchRequest: Codable, Equatable, Sendable {
  public let status: TaskBoardStatus?
  public let itemId: String?
  public let dryRun: Bool
  public let projectDir: String?
  public let actor: String?

  public init(
    status: TaskBoardStatus? = nil,
    itemId: String? = nil,
    dryRun: Bool = true,
    projectDir: String? = nil,
    actor: String? = nil
  ) {
    self.status = status
    self.itemId = itemId
    self.dryRun = dryRun
    self.projectDir = projectDir
    self.actor = actor
  }
}
