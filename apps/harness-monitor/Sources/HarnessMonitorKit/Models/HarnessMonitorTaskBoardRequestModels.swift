import Foundation

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

public struct TaskBoardSetItemPositionRequest: Codable, Equatable, Sendable {
  public let status: TaskBoardStatus
  public let lanePosition: UInt32
  public let expectedItemRevision: Int64
  public let expectedItemsChangeSeq: Int64
  public let actor: String

  public init(
    status: TaskBoardStatus,
    lanePosition: UInt32,
    expectedItemRevision: Int64,
    expectedItemsChangeSeq: Int64,
    actor: String = "Harness Monitor"
  ) {
    self.status = status.canonicalPersistedStatus
    self.lanePosition = lanePosition
    self.expectedItemRevision = expectedItemRevision
    self.expectedItemsChangeSeq = expectedItemsChangeSeq
    self.actor = actor
  }
}

public struct TaskBoardResetItemPositionRequest: Codable, Equatable, Sendable {
  public let expectedItemRevision: Int64
  public let expectedItemsChangeSeq: Int64
  public let actor: String

  public init(
    expectedItemRevision: Int64,
    expectedItemsChangeSeq: Int64,
    actor: String = "Harness Monitor"
  ) {
    self.expectedItemRevision = expectedItemRevision
    self.expectedItemsChangeSeq = expectedItemsChangeSeq
    self.actor = actor
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
