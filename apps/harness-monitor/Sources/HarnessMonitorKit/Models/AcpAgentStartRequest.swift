import Foundation

private func decodeRequiredNonEmptyString<Key: CodingKey>(
  _ container: KeyedDecodingContainer<Key>,
  forKey key: Key
) throws -> String {
  let value = try container.decode(String.self, forKey: key)
  guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
    throw DecodingError.dataCorruptedError(
      forKey: key,
      in: container,
      debugDescription: "\(key.stringValue) must not be empty"
    )
  }
  return value
}
public struct AcpAgentStartRequest: Codable, Equatable, Sendable {
  public let agent: String
  public let role: SessionRole
  public let fallbackRole: SessionRole?
  public let capabilities: [String]
  public let name: String?
  public let prompt: String?
  public let projectDir: String?
  public let persona: String?
  public let taskID: String?
  public let boardItemID: String?
  public let workflowExecutionID: String?
  public let model: String?
  public let effort: String?
  public let allowCustomModel: Bool
  public let recordPermissions: Bool

  public init(
    agent: String,
    role: SessionRole = .worker,
    fallbackRole: SessionRole? = nil,
    capabilities: [String] = [],
    name: String? = nil,
    prompt: String? = nil,
    projectDir: String? = nil,
    persona: String? = nil,
    taskID: String? = nil,
    boardItemID: String? = nil,
    workflowExecutionID: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    allowCustomModel: Bool = false,
    recordPermissions: Bool = false
  ) {
    self.agent = agent
    self.role = role
    self.fallbackRole = fallbackRole
    self.capabilities = capabilities
    self.name = name
    self.prompt = prompt
    self.projectDir = projectDir
    self.persona = persona
    self.taskID = taskID
    self.boardItemID = boardItemID
    self.workflowExecutionID = workflowExecutionID
    self.model = model
    self.effort = effort
    self.allowCustomModel = allowCustomModel
    self.recordPermissions = recordPermissions
  }

  private enum CodingKeys: String, CodingKey {
    case descriptorId
    case role
    case fallbackRole
    case capabilities
    case name
    case prompt
    case projectDir
    case persona
    case taskID = "taskId"
    case boardItemID = "boardItemId"
    case workflowExecutionID = "workflowExecutionId"
    case model
    case effort
    case allowCustomModel
    case recordPermissions
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agent = try decodeRequiredNonEmptyString(container, forKey: .descriptorId)
    role = try container.decodeIfPresent(SessionRole.self, forKey: .role) ?? .worker
    fallbackRole = try container.decodeIfPresent(SessionRole.self, forKey: .fallbackRole)
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    name = try container.decodeIfPresent(String.self, forKey: .name)
    prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
    projectDir = try container.decodeIfPresent(String.self, forKey: .projectDir)
    persona = try container.decodeIfPresent(String.self, forKey: .persona)
    taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
    boardItemID = try container.decodeIfPresent(String.self, forKey: .boardItemID)
    workflowExecutionID = try container.decodeIfPresent(String.self, forKey: .workflowExecutionID)
    model = try container.decodeIfPresent(String.self, forKey: .model)
    effort = try container.decodeIfPresent(String.self, forKey: .effort)
    allowCustomModel =
      try container.decodeIfPresent(Bool.self, forKey: .allowCustomModel) ?? false
    recordPermissions =
      try container.decodeIfPresent(Bool.self, forKey: .recordPermissions) ?? false
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(agent, forKey: .descriptorId)
    try container.encode(role, forKey: .role)
    try container.encodeIfPresent(fallbackRole, forKey: .fallbackRole)
    try container.encode(capabilities, forKey: .capabilities)
    try container.encodeIfPresent(name, forKey: .name)
    try container.encodeIfPresent(prompt, forKey: .prompt)
    try container.encodeIfPresent(projectDir, forKey: .projectDir)
    try container.encodeIfPresent(persona, forKey: .persona)
    try container.encodeIfPresent(taskID, forKey: .taskID)
    try container.encodeIfPresent(boardItemID, forKey: .boardItemID)
    try container.encodeIfPresent(workflowExecutionID, forKey: .workflowExecutionID)
    try container.encodeIfPresent(model, forKey: .model)
    try container.encodeIfPresent(effort, forKey: .effort)
    try container.encode(allowCustomModel, forKey: .allowCustomModel)
    try container.encode(recordPermissions, forKey: .recordPermissions)
  }
}
