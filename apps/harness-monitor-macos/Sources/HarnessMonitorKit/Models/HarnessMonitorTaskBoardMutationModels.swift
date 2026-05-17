import Foundation

public struct TaskBoardUpdateItemRequest: Codable, Equatable, Sendable {
  public let title: String?
  public let body: String?
  public let status: TaskBoardStatus?
  public let priority: TaskBoardPriority?
  public let agentMode: TaskBoardAgentMode?
  public let tags: [String]?
  public let projectId: String?
  public let clearProjectId: Bool
  public let targetProjectTypes: [String]?
  public let externalRefs: [TaskBoardExternalRef]?
  public let planning: TaskBoardPlanningState?
  public let clearPlanning: Bool
  public let workflow: TaskBoardWorkflowState?
  public let clearWorkflow: Bool
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
    targetProjectTypes: [String]? = nil,
    externalRefs: [TaskBoardExternalRef]? = nil,
    planning: TaskBoardPlanningState? = nil,
    clearPlanning: Bool = false,
    workflow: TaskBoardWorkflowState? = nil,
    clearWorkflow: Bool = false,
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
    self.targetProjectTypes = targetProjectTypes
    self.externalRefs = externalRefs
    self.planning = planning
    self.clearPlanning = clearPlanning
    self.workflow = workflow
    self.clearWorkflow = clearWorkflow
    self.sessionId = sessionId
    self.clearSessionId = clearSessionId
    self.workItemId = workItemId
    self.clearWorkItemId = clearWorkItemId
  }
}

public struct TaskBoardListItemsResponse: Codable, Equatable, Sendable {
  public let items: [TaskBoardItem]
}

public struct TaskBoardPlanningTransition: Codable, Equatable, Sendable {
  public let boardItemId: String
  public let fromStatus: TaskBoardStatus
  public let toStatus: TaskBoardStatus
  public let planning: TaskBoardPlanningState

  public init(
    boardItemId: String,
    fromStatus: TaskBoardStatus,
    toStatus: TaskBoardStatus,
    planning: TaskBoardPlanningState
  ) {
    self.boardItemId = boardItemId
    self.fromStatus = fromStatus
    self.toStatus = toStatus
    self.planning = planning
  }
}

public struct TaskBoardPlanningResponse: Codable, Equatable, Sendable {
  public let transition: TaskBoardPlanningTransition
  public let item: TaskBoardItem

  public init(transition: TaskBoardPlanningTransition, item: TaskBoardItem) {
    self.transition = transition
    self.item = item
  }
}

public struct TaskBoardPlanSubmitRequest: Codable, Equatable, Sendable {
  public let summary: String

  public init(summary: String) {
    self.summary = summary
  }
}

public struct TaskBoardPlanApproveRequest: Codable, Equatable, Sendable {
  public let approvedBy: String
  public let approvedAt: String?

  public init(approvedBy: String, approvedAt: String? = nil) {
    self.approvedBy = approvedBy
    self.approvedAt = approvedAt
  }
}

public struct TaskBoardPlanRevokeRequest: Codable, Equatable, Sendable {
  public let actor: String?

  public init(actor: String? = nil) {
    self.actor = actor
  }
}
