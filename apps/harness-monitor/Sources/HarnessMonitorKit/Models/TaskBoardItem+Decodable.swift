import Foundation

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
    case sourceProjectId
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
    self.sourceProjectId = try container.decodeIfPresent(String.self, forKey: .sourceProjectId)
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
