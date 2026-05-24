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
    payloadJSON: String,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.tickID = tickID
    self.kind = kind
    self.ruleID = ruleID
    self.severityRaw = severity?.rawValue
    self.payloadJSON = payloadJSON
    self.createdAt = createdAt
  }
}

extension SupervisorEvent {
  /// Stable raw strings persisted on `SupervisorEvent.kind`. The cases mirror the four event types
  /// `PolicyExecutor` writes today; new cases must preserve existing raw values so old rows decode.
  public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
    case actionDispatched
    case actionExecuted
    case actionFailed
    case actionSuppressed
  }

  /// Severity tag for an audit row. Mirrors `DecisionSeverity` so consumers can reuse the same
  /// enum across decision and audit surfaces.
  public typealias Severity = DecisionSeverity
}

public struct SupervisorEventSnapshot: Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let tickID: String
  public let kind: String
  public let ruleID: String?
  public let severityRaw: String?
  public let payloadJSON: String
  public let createdAt: Date

  public init(
    id: String,
    tickID: String,
    kind: String,
    ruleID: String?,
    severityRaw: String?,
    payloadJSON: String,
    createdAt: Date
  ) {
    self.id = id
    self.tickID = tickID
    self.kind = kind
    self.ruleID = ruleID
    self.severityRaw = severityRaw
    self.payloadJSON = payloadJSON
    self.createdAt = createdAt
  }

  public init(event: SupervisorEvent) {
    self.init(
      id: event.id,
      tickID: event.tickID,
      kind: event.kind,
      ruleID: event.ruleID,
      severityRaw: event.severityRaw,
      payloadJSON: event.payloadJSON,
      createdAt: event.createdAt
    )
  }
}
