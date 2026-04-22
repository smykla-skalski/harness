import Foundation
import SwiftData

/// Audit event row for the Monitor supervisor loop. Every tick phase — snapshot, rule
/// evaluation, action dispatch/execute/fail, quarantine, observer suggestion — lands as one
/// row. Public field list is part of the Phase 1 signature freeze.
@Model
public final class SupervisorEvent {
  @Attribute(.unique) public var id: String
  public var tickID: String
  public var kind: String
  public var ruleID: String?
  public var severityRaw: String?
  public var payloadJSON: String
  public var createdAt: Date

  public init(
    id: String,
    tickID: String,
    kind: String,
    ruleID: String?,
    severity: DecisionSeverity?,
    payloadJSON: String
  ) {
    self.id = id
    self.tickID = tickID
    self.kind = kind
    self.ruleID = ruleID
    self.severityRaw = severity?.rawValue
    self.payloadJSON = payloadJSON
    self.createdAt = Date()
  }
}
