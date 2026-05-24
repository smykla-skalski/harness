public struct DecisionDraft: Sendable, Hashable {
  public let id: String
  public let severity: DecisionSeverity
  public let ruleID: String
  public let sessionID: String?
  public let agentID: String?
  public let taskID: String?
  public let summary: String
  public let contextJSON: String
  public let suggestedActionsJSON: String

  public init(
    id: String,
    severity: DecisionSeverity,
    ruleID: String,
    sessionID: String?,
    agentID: String?,
    taskID: String?,
    summary: String,
    contextJSON: String,
    suggestedActionsJSON: String
  ) {
    self.id = id
    self.severity = severity
    self.ruleID = ruleID
    self.sessionID = sessionID
    self.agentID = agentID
    self.taskID = taskID
    self.summary = summary
    self.contextJSON = contextJSON
    self.suggestedActionsJSON = suggestedActionsJSON
  }
}

public struct DecisionOutcome: Codable, Sendable, Hashable {
  public let chosenActionID: String?
  public let note: String?

  public init(chosenActionID: String?, note: String?) {
    self.chosenActionID = chosenActionID
    self.note = note
  }
}
