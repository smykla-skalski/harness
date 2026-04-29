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
