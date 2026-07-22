import Foundation

public struct TaskBoardCapabilities: Codable, Equatable, Sendable {
  public let storage: String
  public let revision: UInt64
  public let instanceID: String

  public init(storage: String, revision: UInt64, instanceID: String) {
    self.storage = storage
    self.revision = revision
    self.instanceID = instanceID
  }

  enum CodingKeys: String, CodingKey {
    case storage
    case revision
    case instanceID = "instance_id"
  }
}

extension TaskBoardStatus {
  public static let currentLaneCases: [Self] = [
    .backlog,
    .todo,
    .planning,
    .inProgress,
    .agenticReview,
    .testing,
    .inReview,
    .toReview,
    .humanRequired,
    .failed,
  ]

  public var canonicalPersistedStatus: Self {
    switch self {
    case .new:
      .todo
    case .planReview:
      .agenticReview
    case .needsYou:
      .humanRequired
    case .blocked:
      .failed
    default:
      self
    }
  }

  public var title: String {
    switch self {
    case .backlog:
      "Backlog"
    case .todo:
      "Todo"
    case .new:
      "New"
    case .planning:
      "Planning"
    case .agenticReview:
      "Agentic Review"
    case .planReview:
      "Plan Review"
    case .needsYou:
      "Needs You"
    case .inProgress:
      "In Progress"
    case .testing:
      "Testing"
    case .inReview:
      "In Review"
    case .toReview:
      "To Review"
    case .humanRequired:
      "Human Required"
    case .failed:
      "Failed"
    case .done:
      "Done"
    case .blocked:
      "Blocked"
    case .unknown(let raw):
      raw
    }
  }
}

extension TaskBoardPriority {
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

extension TaskBoardAgentMode {
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
  case gitHub = "github"
  case todoist

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let rawValue = try container.decode(String.self)
    switch rawValue {
    case "github", "git_hub": self = .gitHub
    case "todoist": self = .todoist
    default:
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unknown task-board external reference provider: \(rawValue)"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

public struct TaskBoardExternalRefSyncState: Codable, Equatable, Sendable {
  public let status: TaskBoardStatus?

  public init(status: TaskBoardStatus? = nil) {
    self.status = status
  }
}

public struct TaskBoardExternalRef: Codable, Equatable, Sendable {
  public let provider: TaskBoardExternalRefProvider
  public let externalId: String
  public let url: String?
  public let syncState: TaskBoardExternalRefSyncState?

  public init(
    provider: TaskBoardExternalRefProvider,
    externalId: String,
    url: String? = nil,
    syncState: TaskBoardExternalRefSyncState? = nil
  ) {
    self.provider = provider
    self.externalId = externalId
    self.url = url
    self.syncState = syncState
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
  /// GitHub-imported items leave `projectId` empty and carry their source repository here.
  public let executionRepository: String?
  public let targetProjectTypes: [String]
  public let agentMode: TaskBoardAgentMode
  public let kind: TaskBoardItemKind
  public let externalRefs: [TaskBoardExternalRef]
  public let importedFromProvider: TaskBoardExternalRefProvider?
  public let planning: TaskBoardPlanningState
  public let workflow: TaskBoardWorkflowState?
  public let sessionId: String?
  public let workItemId: String?
  public let usage: TaskBoardUsage
  public let parentItemId: String?
  public let childOrder: UInt32
  public let lanePosition: UInt32?
  public let laneOrigin: TaskBoardLaneOrigin?
  public let laneSetAt: String?
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
    executionRepository: String? = nil,
    targetProjectTypes: [String] = [],
    agentMode: TaskBoardAgentMode,
    kind: TaskBoardItemKind = .task,
    externalRefs: [TaskBoardExternalRef],
    importedFromProvider: TaskBoardExternalRefProvider? = nil,
    planning: TaskBoardPlanningState,
    workflow: TaskBoardWorkflowState?,
    sessionId: String?,
    workItemId: String?,
    usage: TaskBoardUsage,
    parentItemId: String? = nil,
    childOrder: UInt32 = 0,
    lanePosition: UInt32? = nil,
    laneOrigin: TaskBoardLaneOrigin? = nil,
    laneSetAt: String? = nil,
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
    self.executionRepository = executionRepository
    self.targetProjectTypes = targetProjectTypes
    self.agentMode = agentMode
    self.kind = kind
    self.externalRefs = externalRefs
    self.importedFromProvider = importedFromProvider
    self.planning = planning
    self.workflow = workflow
    self.sessionId = sessionId
    self.workItemId = workItemId
    self.usage = usage
    self.parentItemId = parentItemId
    self.childOrder = childOrder
    self.lanePosition = lanePosition
    self.laneOrigin = laneOrigin
    self.laneSetAt = laneSetAt
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
    case executionRepository
    case targetProjectTypes
    case agentMode
    case kind
    case externalRefs
    case importedFromProvider
    case planning
    case workflow
    case sessionId
    case workItemId
    case usage
    case parentItemId
    case childOrder
    case lanePosition
    case laneOrigin
    case laneSetAt
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
    self.executionRepository =
      try container.decodeIfPresent(String.self, forKey: .executionRepository)
    self.targetProjectTypes =
      try container.decodeIfPresent([String].self, forKey: .targetProjectTypes) ?? []
    self.agentMode = try container.decode(TaskBoardAgentMode.self, forKey: .agentMode)
    self.kind = try container.decodeIfPresent(TaskBoardItemKind.self, forKey: .kind) ?? .task
    self.externalRefs =
      try container.decodeIfPresent([TaskBoardExternalRef].self, forKey: .externalRefs) ?? []
    self.importedFromProvider =
      try container.decodeIfPresent(
        TaskBoardExternalRefProvider.self,
        forKey: .importedFromProvider
      )
    self.planning = try container.decode(TaskBoardPlanningState.self, forKey: .planning)
    self.workflow = try container.decodeIfPresent(TaskBoardWorkflowState.self, forKey: .workflow)
    self.sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    self.workItemId = try container.decodeIfPresent(String.self, forKey: .workItemId)
    self.usage = try container.decode(TaskBoardUsage.self, forKey: .usage)
    self.parentItemId = try container.decodeIfPresent(String.self, forKey: .parentItemId)
    self.childOrder = try container.decodeIfPresent(UInt32.self, forKey: .childOrder) ?? 0
    self.lanePosition = try container.decodeIfPresent(UInt32.self, forKey: .lanePosition)
    self.laneOrigin = try container.decodeIfPresent(TaskBoardLaneOrigin.self, forKey: .laneOrigin)
    self.laneSetAt = try container.decodeIfPresent(String.self, forKey: .laneSetAt)
    self.createdAt = try container.decode(String.self, forKey: .createdAt)
    self.updatedAt = try container.decode(String.self, forKey: .updatedAt)
    self.deletedAt = try container.decodeIfPresent(String.self, forKey: .deletedAt)
  }
}
