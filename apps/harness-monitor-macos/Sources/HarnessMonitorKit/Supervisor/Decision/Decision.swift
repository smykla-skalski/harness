import Foundation
import SwiftData

/// SwiftData-persisted Monitor supervisor decision row. Public field list is part of the
/// Phase 1 signature freeze — Phase 2 workers must not add, rename, or remove fields.
/// Schema membership lives in `HarnessMonitorSchemaV7`.
@Model
public final class Decision {
  @Attribute(.unique)
  public var id: String
  public var severityRaw: String
  public var ruleID: String
  public var sessionID: String?
  public var agentID: String?
  public var taskID: String?
  public var summary: String
  public var contextJSON: String
  public var suggestedActionsJSON: String
  public var createdAt: Date
  public var snoozedUntil: Date?
  public var statusRaw: String
  public var resolutionJSON: String?

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
    self.severityRaw = severity.rawValue
    self.ruleID = ruleID
    self.sessionID = sessionID
    self.agentID = agentID
    self.taskID = taskID
    self.summary = summary
    self.contextJSON = contextJSON
    self.suggestedActionsJSON = suggestedActionsJSON
    self.createdAt = Date()
    self.snoozedUntil = nil
    self.statusRaw = "open"
    self.resolutionJSON = nil
  }
}
