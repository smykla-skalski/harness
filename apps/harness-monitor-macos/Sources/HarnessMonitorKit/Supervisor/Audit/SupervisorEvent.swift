import Foundation
import SwiftData

/// Audit event row for the Monitor supervisor loop.
///
/// UI-0 contract:
/// - This is the current persisted audit-entry carrier for decision work, including future ACP
///   permission rows until a more specific type proves necessary.
/// - `payloadJSON` is the extensibility slot for decision-specific shape. The ACP path will need
///   to encode partial approvals as an embedded approved-request-id array and may later add a
///   `uiAnnotation` field for races such as ACTA scenario (b) cancelled turn mid-tool-call and
///   scenario (e) `session/cancel` during stream.
/// - Public field list is still Phase 1 schema-frozen; evolve the payload shape before evolving
///   the row shape.
@Model
public final class SupervisorEvent {
  @Attribute(.unique)
  public var id: String
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
