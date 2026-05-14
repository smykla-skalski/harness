import Foundation

public enum TaskBoardStatus: String, Codable, CaseIterable, Identifiable, Sendable {
  case new
  case planning
  case planReview = "plan_review"
  case todo
  case inProgress = "in_progress"
  case inReview = "in_review"
  case done
  case blocked

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .new:
      "New"
    case .planning:
      "Planning"
    case .planReview:
      "Plan Review"
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

public enum TaskBoardAgentMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case headless
  case interactive
  case planning
  case evaluate

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
    self.prUrl = prUrl
    self.lastError = lastError
    self.policyTraceIds = policyTraceIds
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
}

public struct TaskBoardCreateItemRequest: Codable, Equatable, Sendable {
  public let title: String
  public let body: String
  public let priority: TaskBoardPriority
  public let agentMode: TaskBoardAgentMode
  public let tags: [String]
  public let projectId: String?
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

public struct TaskBoardUpdateItemRequest: Codable, Equatable, Sendable {
  public let title: String?
  public let body: String?
  public let status: TaskBoardStatus?
  public let priority: TaskBoardPriority?
  public let agentMode: TaskBoardAgentMode?
  public let tags: [String]?
  public let projectId: String?
  public let clearProjectId: Bool
  public let externalRefs: [TaskBoardExternalRef]?
  public let planning: TaskBoardPlanningState?
  public let workflow: TaskBoardWorkflowState?
  public let sessionId: String?
  public let clearSessionId: Bool
  public let workItemId: String?
  public let clearWorkItemId: Bool

  public init(
    title: String? = nil,
    body: String? = nil,
    status: TaskBoardStatus? = nil,
    priority: TaskBoardPriority? = nil,
    agentMode: TaskBoardAgentMode? = nil,
    tags: [String]? = nil,
    projectId: String? = nil,
    clearProjectId: Bool = false,
    externalRefs: [TaskBoardExternalRef]? = nil,
    planning: TaskBoardPlanningState? = nil,
    workflow: TaskBoardWorkflowState? = nil,
    sessionId: String? = nil,
    clearSessionId: Bool = false,
    workItemId: String? = nil,
    clearWorkItemId: Bool = false
  ) {
    self.title = title
    self.body = body
    self.status = status
    self.priority = priority
    self.agentMode = agentMode
    self.tags = tags
    self.projectId = projectId
    self.clearProjectId = clearProjectId
    self.externalRefs = externalRefs
    self.planning = planning
    self.workflow = workflow
    self.sessionId = sessionId
    self.clearSessionId = clearSessionId
    self.workItemId = workItemId
    self.clearWorkItemId = clearWorkItemId
  }
}

public struct TaskBoardListItemsResponse: Codable, Equatable, Sendable {
  public let items: [TaskBoardItem]
}
