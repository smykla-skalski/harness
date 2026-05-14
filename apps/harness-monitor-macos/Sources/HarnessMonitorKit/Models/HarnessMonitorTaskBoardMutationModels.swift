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
