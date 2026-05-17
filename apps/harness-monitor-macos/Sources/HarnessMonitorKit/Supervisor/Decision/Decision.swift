import Foundation
import SwiftData

/// SwiftData-persisted Monitor decision queue row.
///
/// UI-0 contract:
/// - The operating goal is single-queue policy enforcement, not interruption fidelity. A decision
///   must remain resolvable and auditable even if the original presenting surface changes.
/// - Future ACP permission rows join this same queue instead of opening a second modal-owned
///   state machine.
/// - Batch toggle state is intentionally UI-ephemeral. It may survive selection changes within
///   one window lifetime, but it must be dropped on window close instead of persisting in
///   `Decision` storage.
/// - Sticky selection belongs to the current decision identity, but enforcement is staged.
///   Today's ACP queue keeps the presented batch stable during active resolution flows; broader
///   "do not steal focus while the operator is mid-toggle" behavior lands with the Decisions-first
///   ACP UI that owns those toggles.
///
/// Public field list is part of the Phase 1 signature freeze. Phase 2 workers must not add,
/// rename, or remove fields. Schema membership lives in `HarnessMonitorSchemaV7`.
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
    suggestedActionsJSON: String,
    createdAt: Date = Date()
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
    self.createdAt = createdAt
    self.snoozedUntil = nil
    self.statusRaw = "open"
    self.resolutionJSON = nil
  }
}

/// Value snapshot for decision presentation/indexing work.
///
/// `Decision` is a SwiftData model, so Monitor views should capture the fields
/// they need once at the persistence/store boundary and hand this value type to
/// worker actors for filtering, grouping, sorting, and indexing.
public struct DecisionPresentationSnapshot: Equatable, Hashable, Sendable, Identifiable {
  public let id: String
  public let sessionID: String?
  public let severityRaw: String
  public let summary: String
  public let ruleID: String
  public let agentID: String?
  public let taskID: String?
  public let suggestedActionsJSON: String
  public let createdAt: Date
  public let statusRaw: String

  public init(
    id: String,
    sessionID: String?,
    severityRaw: String,
    summary: String,
    ruleID: String,
    agentID: String?,
    taskID: String?,
    suggestedActionsJSON: String,
    createdAt: Date,
    statusRaw: String
  ) {
    self.id = id
    self.sessionID = sessionID
    self.severityRaw = severityRaw
    self.summary = summary
    self.ruleID = ruleID
    self.agentID = agentID
    self.taskID = taskID
    self.suggestedActionsJSON = suggestedActionsJSON
    self.createdAt = createdAt
    self.statusRaw = statusRaw
  }

  public init(decision: Decision) {
    self.init(
      id: decision.id,
      sessionID: decision.sessionID,
      severityRaw: decision.severityRaw,
      summary: decision.summary,
      ruleID: decision.ruleID,
      agentID: decision.agentID,
      taskID: decision.taskID,
      suggestedActionsJSON: decision.suggestedActionsJSON,
      createdAt: decision.createdAt,
      statusRaw: decision.statusRaw
    )
  }
}
