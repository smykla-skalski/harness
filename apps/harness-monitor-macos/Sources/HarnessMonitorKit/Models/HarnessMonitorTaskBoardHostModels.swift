import Foundation

public struct TaskBoardHostMachine: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let projectTypes: [String]
  public let agentModes: [TaskBoardAgentMode]
  public let lastSeen: String

  public init(
    id: String,
    label: String,
    projectTypes: [String] = [],
    agentModes: [TaskBoardAgentMode] = [],
    lastSeen: String
  ) {
    self.id = id
    self.label = label
    self.projectTypes = projectTypes
    self.agentModes = agentModes
    self.lastSeen = lastSeen
  }

  enum CodingKeys: String, CodingKey {
    case id
    case label
    case projectTypes
    case agentModes
    case lastSeen
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      label: try container.decode(String.self, forKey: .label),
      projectTypes: try container.decodeIfPresent([String].self, forKey: .projectTypes) ?? [],
      agentModes: try container.decodeIfPresent([TaskBoardAgentMode].self, forKey: .agentModes)
        ?? [],
      lastSeen: try container.decode(String.self, forKey: .lastSeen)
    )
  }
}

public struct TaskBoardHostSetProjectTypesRequest: Codable, Equatable, Sendable {
  public let projectTypes: [String]

  public init(projectTypes: [String] = []) {
    self.projectTypes = projectTypes
  }
}
